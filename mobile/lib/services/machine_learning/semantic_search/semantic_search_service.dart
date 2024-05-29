import "dart:async";
import "dart:collection";
import "dart:math" show min;

import "package:computer/computer.dart";
import "package:flutter/foundation.dart" show kDebugMode;
import "package:logging/logging.dart";
import "package:ml_linalg/linalg.dart";
import "package:photos/core/cache/lru_map.dart";
import "package:photos/core/configuration.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/embeddings_db.dart";
import "package:photos/db/files_db.dart";
import "package:photos/events/diff_sync_complete_event.dart";
import 'package:photos/events/embedding_updated_event.dart';
import "package:photos/events/file_uploaded_event.dart";
import "package:photos/events/machine_learning_control_event.dart";
import "package:photos/extensions/stop_watch.dart";
import "package:photos/models/embedding.dart";
import "package:photos/models/file/file.dart";
import "package:photos/services/collections_service.dart";
import 'package:photos/services/machine_learning/semantic_search/embedding_store.dart';
import 'package:photos/services/machine_learning/semantic_search/frameworks/ggml.dart';
import 'package:photos/services/machine_learning/semantic_search/frameworks/ml_framework.dart';
import 'package:photos/services/machine_learning/semantic_search/frameworks/onnx/onnx.dart';
import "package:photos/utils/debouncer.dart";
import "package:photos/utils/device_info.dart";
import "package:photos/utils/local_settings.dart";
import "package:photos/utils/ml_util.dart";
import "package:photos/utils/thumbnail_util.dart";

class SemanticSearchService {
  SemanticSearchService._privateConstructor();

  static final SemanticSearchService instance = SemanticSearchService._privateConstructor();
  static final Computer _computer = Computer.shared();
  static final LRUMap<String, List<double>> _queryCache = LRUMap(20);

  static const kEmbeddingLength = 512;
  static const kScoreThreshold = 0.23;
  static const kShouldPushEmbeddings = true;
  static const kDebounceDuration = Duration(milliseconds: 4000);

  final _logger = Logger("SemanticSearchService");
  final _queue = Queue<EnteFile>();
  final _frameworkInitialization = Completer<bool>();
  final _embeddingLoaderDebouncer =
      Debouncer(kDebounceDuration, executionInterval: kDebounceDuration);

  late Model _currentModel;
  late MLFramework _mlFramework;
  bool _hasInitialized = false;
  bool _isComputingEmbeddings = false;
  bool _isSyncing = false;
  List<Embedding> _cachedEmbeddings = <Embedding>[];
  List<EmbeddingVector> _cachedVectors = <EmbeddingVector>[];
  Future<(String, List<EnteFile>)>? _searchScreenRequest;
  String? _latestPendingQuery;

  Completer<void> _mlController = Completer<void>();

  get hasInitialized => _hasInitialized;

  Future<void> init({bool shouldSyncImmediately = false}) async {
    if (!LocalSettings.instance.hasEnabledMagicSearch()) {
      return;
    }
    if (_hasInitialized) {
      _logger.info("Initialized already");
      return;
    }
    _hasInitialized = true;
    final shouldDownloadOverMobileData = Configuration.instance.shouldBackupOverMobileData();
    _currentModel = await _getCurrentModel();
    _mlFramework = _currentModel == Model.onnxClip
        ? ONNX(shouldDownloadOverMobileData)
        : GGML(shouldDownloadOverMobileData);
    await EmbeddingStore.instance.init();
    await EmbeddingsDB.instance.init();
    await _loadEmbeddings();
    Bus.instance.on<EmbeddingUpdatedEvent>().listen((event) {
      _embeddingLoaderDebouncer.run(() async {
        await _loadEmbeddings();
      });
    });
    Bus.instance.on<DiffSyncCompleteEvent>().listen((event) {
      // Diff sync is complete, we can now pull embeddings from remote
      unawaited(sync());
    });
    if (Configuration.instance.hasConfiguredAccount() && kShouldPushEmbeddings) {
      unawaited(EmbeddingStore.instance.pushEmbeddings());
    }

    // ignore: unawaited_futures
    _loadModels().then((v) async {
      _logger.info("Getting text embedding");
      await _getTextEmbedding("warm up text encoder");
      _logger.info("Got text embedding");
    });
    // Adding to queue only on init?
    Bus.instance.on<FileUploadedEvent>().listen((event) async {
      _addToQueue(event.file);
    });
    if (shouldSyncImmediately) {
      unawaited(sync());
    }
    Bus.instance.on<MachineLearningControlEvent>().listen((event) {
      if (event.shouldRun) {
        _startIndexing();
      } else {
        _pauseIndexing();
      }
    });
  }

  Future<void> release() async {
    if (_frameworkInitialization.isCompleted) {
      await _mlFramework.release();
    }
  }

  Future<void> sync() async {
    if (_isSyncing) {
      return;
    }
    _isSyncing = true;
    final fetchCompleted = await EmbeddingStore.instance.pullEmbeddings(_currentModel);
    if (fetchCompleted) {
      await _backFill();
    }
    _isSyncing = false;
  }

  // searchScreenQuery should only be used for the user initiate query on the search screen.
  // If there are multiple call tho this method, then for all the calls, the result will be the same as the last query.
  Future<(String, List<EnteFile>)> searchScreenQuery(String query) async {
    if (!LocalSettings.instance.hasEnabledMagicSearch() || !_frameworkInitialization.isCompleted) {
      return (query, <EnteFile>[]);
    }
    // If there's an ongoing request, just update the last query and return its future.
    if (_searchScreenRequest != null) {
      _latestPendingQuery = query;
      return _searchScreenRequest!;
    } else {
      // No ongoing request, start a new search.
      _searchScreenRequest = _getMatchingFiles(query).then((result) {
        // Search completed, reset the ongoing request.
        _searchScreenRequest = null;
        // If there was a new query during the last search, start a new search with the last query.
        if (_latestPendingQuery != null) {
          final String newQuery = _latestPendingQuery!;
          _latestPendingQuery = null; // Reset last query.
          // Recursively call search with the latest query.
          return searchScreenQuery(newQuery);
        }
        return (query, result);
      });
      return _searchScreenRequest!;
    }
  }

  Future<IndexStatus> getIndexStatus() async {
    final indexableFileIDs = await getIndexableFileIDs();
    return IndexStatus(
      min(_cachedEmbeddings.length, indexableFileIDs.length),
      (await _getFileIDsToBeIndexed()).length,
    );
  }

  InitializationState getFrameworkInitializationState() {
    if (!_hasInitialized) {
      return InitializationState.notInitialized;
    }
    return _mlFramework.initializationState;
  }

  Future<void> clearIndexes() async {
    await EmbeddingStore.instance.clearEmbeddings(_currentModel);
    _logger.info("Indexes cleared for $_currentModel");
  }

  Future<void> _loadEmbeddings() async {
    _logger.info("Pulling cached embeddings");
    final startTime = DateTime.now();
    _cachedEmbeddings = await EmbeddingsDB.instance.getAll(_currentModel);
    _cachedVectors = _cachedEmbeddings
        .map(
          (e) => EmbeddingVector(
            fileID: e.fileID,
            model: e.model,
            embedding: Vector.fromList(e.embedding),
          ),
        )
        .toList();
    for (final vector in _cachedVectors) {
      assert(
        (1 - vector.embedding.norm()).abs() < 1e-3,
        "Embedding vector is not normalized, norm: ${vector.embedding.norm()}",
      );
    }
    final endTime = DateTime.now();
    _logger.info(
      "Loading ${_cachedEmbeddings.length} took: ${(endTime.millisecondsSinceEpoch - startTime.millisecondsSinceEpoch)}ms",
    );
    Bus.instance.fire(EmbeddingCacheUpdatedEvent());
    _logger.info("Cached embeddings: " + _cachedEmbeddings.length.toString());
  }

  Future<void> _backFill() async {
    if (!LocalSettings.instance.hasEnabledMagicSearch() || !MLFramework.kImageEncoderEnabled) {
      return;
    }
    await _frameworkInitialization.future;
    _logger.info("Attempting backfill for image embeddings");
    final fileIDs = await _getFileIDsToBeIndexed();
    final files = await FilesDB.instance.getUploadedFiles(fileIDs);
    _logger.info(files.length.toString() + " to be embedded");
    // await _cacheThumbnails(files);
    _queue.addAll(files);
    unawaited(_pollQueue());
  }

  Future<void> _cacheThumbnails(List<EnteFile> files) async {
    int counter = 0;
    const batchSize = 100;
    for (var i = 0; i < files.length;) {
      final futures = <Future>[];
      for (var j = 0; j < batchSize && i < files.length; j++, i++) {
        futures.add(getThumbnail(files[i]));
      }
      await Future.wait(futures);
      counter += futures.length;
      _logger.info("$counter/${files.length} thumbnails cached");
    }
  }

  Future<List<int>> _getFileIDsToBeIndexed() async {
    final uploadedFileIDs = await getIndexableFileIDs();
    final embeddedFileIDs = await EmbeddingsDB.instance.getFileIDs(_currentModel);

    uploadedFileIDs.removeWhere(
      (id) => embeddedFileIDs.contains(id),
    );
    return uploadedFileIDs;
  }

  Future<void> clearQueue() async {
    _queue.clear();
  }

  Future<List<EnteFile>> _getMatchingFiles(String query) async {
    final textEmbedding = await _getTextEmbedding(query);

    final queryResults = await _getScores(textEmbedding);

    final filesMap = await FilesDB.instance.getFilesFromIDs(queryResults.map((e) => e.id).toList());
    final results = <EnteFile>[];

    final ignoredCollections = CollectionsService.instance.getHiddenCollectionIds();
    final deletedEntries = <int>[];
    for (final result in queryResults) {
      final file = filesMap[result.id];
      if (file != null && !ignoredCollections.contains(file.collectionID)) {
        results.add(file);
      }
      if (file == null) {
        deletedEntries.add(result.id);
      }
    }

    _logger.info(results.length.toString() + " results");

    if (deletedEntries.isNotEmpty) {
      unawaited(EmbeddingsDB.instance.deleteEmbeddings(deletedEntries));
    }

    return results;
  }

  void _addToQueue(EnteFile file) {
    if (!LocalSettings.instance.hasEnabledMagicSearch()) {
      return;
    }
    _logger.info("Adding " + file.toString() + " to the queue");
    _queue.add(file);
    _pollQueue();
  }

  Future<void> _loadModels() async {
    _logger.info("Initializing ML framework");
    try {
      await _mlFramework.init();
      _frameworkInitialization.complete(true);
    } catch (e, s) {
      _logger.severe("ML framework initialization failed", e, s);
    }
    _logger.info("ML framework initialized");
  }

  Future<void> _pollQueue() async {
    if (_isComputingEmbeddings) {
      return;
    }
    _isComputingEmbeddings = true;

    while (_queue.isNotEmpty) {
      await computeImageEmbedding(_queue.removeLast());
    }

    _isComputingEmbeddings = false;
  }

  Future<void> computeImageEmbedding(EnteFile file) async {
    if (!MLFramework.kImageEncoderEnabled) {
      return;
    }
    if (!_frameworkInitialization.isCompleted) {
      return;
    }
    if (!_mlController.isCompleted) {
      _logger.info("Waiting for a green signal from controller...");
      await _mlController.future;
    }
    try {
      final thumbnail = await getThumbnailForUploadedFile(file);
      if (thumbnail == null) {
        _logger.warning("Could not get thumbnail for $file");
        return;
      }
      final filePath = thumbnail.path;
      _logger.info("Running clip over $file");
      final result = await _mlFramework.getImageEmbedding(filePath);
      if (result.length != kEmbeddingLength) {
        _logger.severe("Discovered incorrect embedding for $file - $result");
        return;
      }

      final embedding = Embedding(
        fileID: file.uploadedFileID!,
        model: _currentModel,
        embedding: result,
      );
      await EmbeddingStore.instance.storeEmbedding(
        file,
        embedding,
      );
    } catch (e, s) {
      _logger.severe(e, s);
    }
  }

  Future<List<double>> _getTextEmbedding(String query) async {
    _logger.info("Searching for " + query);
    final cachedResult = _queryCache.get(query);
    if (cachedResult != null) {
      return cachedResult;
    }
    try {
      final result = await _mlFramework.getTextEmbedding(query);
      _queryCache.put(query, result);
      return result;
    } catch (e) {
      _logger.severe("Could not get text embedding", e);
      return [];
    }
  }

  Future<List<QueryResult>> _getScores(List<double> textEmbedding) async {
    final startTime = DateTime.now();
    final List<QueryResult> queryResults = await _computer.compute(
      computeBulkScore,
      param: {
        "imageEmbeddings": _cachedEmbeddings,
        "textEmbedding": textEmbedding,
      },
      taskName: "computeBulkScore",
    );
    // final List<QueryResult> queryResults = await _computer.compute(
    //   computeBulkScoreFaster,
    //   param: {
    //     "imageEmbeddings": _cachedVectors,
    //     "textEmbedding": textEmbedding,
    //   },
    //   taskName: "computeBulkScore",
    // );
    final endTime = DateTime.now();
    _logger.info(
      "computingScores took: " +
          (endTime.millisecondsSinceEpoch - startTime.millisecondsSinceEpoch).toString() +
          "ms",
    );
    return queryResults;
  }

  Future<Model> _getCurrentModel() async {
    if (await isGrapheneOS()) {
      return Model.ggmlClip;
    } else {
      return Model.onnxClip;
    }
  }

  void _startIndexing() {
    _logger.info("Start indexing");
    if (!_mlController.isCompleted) {
      _mlController.complete();
    }
  }

  void _pauseIndexing() {
    if (_mlController.isCompleted) {
      _logger.info("Pausing indexing");
      _mlController = Completer<void>();
    }
  }
}

List<QueryResult> computeBulkScoreFaster(Map args) {
  final w = (kDebugMode ? EnteWatch('clip cosime similarity calculation faster') : null)?..start();
  final queryResults = <QueryResult>[];
  final imageEmbeddings = args["imageEmbeddings"] as List<EmbeddingVector>;
  final textEmbedding = args["textEmbedding"] as List<double>;
  final textVector = Vector.fromList(textEmbedding);
  for (final imageEmbedding in imageEmbeddings) {
    final cosineSim = imageEmbedding.embedding.dot(textVector);
    if (cosineSim >= SemanticSearchService.kScoreThreshold) {
      queryResults.add(QueryResult(imageEmbedding.fileID, cosineSim));
    }
  }
  w?.log('cosine similarity calculation done');

  queryResults.sort((first, second) => second.score.compareTo(first.score));
  return queryResults;
}

List<QueryResult> computeBulkScore(Map args) {
  final w = (kDebugMode ? EnteWatch('clip cosime similarity calculation old') : null)?..start();
  final queryResults = <QueryResult>[];
  final imageEmbeddings = args["imageEmbeddings"] as List<Embedding>;
  final textEmbedding = args["textEmbedding"] as List<double>;
  for (final imageEmbedding in imageEmbeddings) {
    final score = computeScore(
      imageEmbedding.embedding,
      textEmbedding,
    );
    if (score >= SemanticSearchService.kScoreThreshold) {
      queryResults.add(QueryResult(imageEmbedding.fileID, score));
    }
  }
  w?.log('cosine similarity calculation done');

  queryResults.sort((first, second) => second.score.compareTo(first.score));
  return queryResults;
}

double computeScore(List<double> imageEmbedding, List<double> textEmbedding) {
  assert(
    imageEmbedding.length == textEmbedding.length,
    "The two embeddings should have the same length",
  );
  double score = 0;
  for (int index = 0; index < imageEmbedding.length; index++) {
    score += imageEmbedding[index] * textEmbedding[index];
  }
  return score;
}

class QueryResult {
  final int id;
  final double score;

  QueryResult(this.id, this.score);
}

class IndexStatus {
  final int indexedItems, pendingItems;

  IndexStatus(this.indexedItems, this.pendingItems);
}
