import { haveWindow } from "@/next/env";
import log from "@/next/log";
import { ComlinkWorker } from "@/next/worker/comlink-worker";
import { getDedicatedCryptoWorker } from "@ente/shared/crypto";
import { DedicatedCryptoWorker } from "@ente/shared/crypto/internal/crypto.worker";
import { CustomError, parseUploadErrorCodes } from "@ente/shared/error";
import PQueue from "p-queue";
import mlIDbStorage, { ML_SEARCH_CONFIG_NAME } from "services/face/db";
import { fetchImageBitmap, getLocalFile } from "services/face/file";
import { putFaceEmbedding } from "services/face/remote";
import { MlFileData } from "services/face/types";
import { getLocalFiles } from "services/fileService";
import { EnteFile } from "types/file";
import { isInternalUserForML } from "utils/user";
import { indexFaces, saveFaceCrop } from "../face/f-index";

/**
 * TODO-ML(MR): What and why.
 * Also, needs to be 1 (in sync with mobile) when we move out of beta.
 */
export const defaultMLVersion = 3;

const batchSize = 200;

export const MAX_ML_SYNC_ERROR_COUNT = 1;

export interface MLSearchConfig {
    enabled: boolean;
}

export const DEFAULT_ML_SEARCH_CONFIG: MLSearchConfig = {
    enabled: false,
};

export async function getMLSearchConfig() {
    if (isInternalUserForML()) {
        return mlIDbStorage.getConfig(
            ML_SEARCH_CONFIG_NAME,
            DEFAULT_ML_SEARCH_CONFIG,
        );
    }
    // Force disabled for everyone else while we finalize it to avoid redundant
    // reindexing for users.
    return DEFAULT_ML_SEARCH_CONFIG;
}

export async function updateMLSearchConfig(newConfig: MLSearchConfig) {
    return mlIDbStorage.putConfig(ML_SEARCH_CONFIG_NAME, newConfig);
}

class MLSyncContext {
    public token: string;
    public userID: number;

    public localFilesMap: Map<number, EnteFile>;
    public outOfSyncFiles: EnteFile[];
    public nSyncedFiles: number;

    public error?: Error;

    public syncQueue: PQueue;
    // TODO: wheather to limit concurrent downloads
    // private downloadQueue: PQueue;

    private concurrency: number;
    private comlinkCryptoWorker: Array<
        ComlinkWorker<typeof DedicatedCryptoWorker>
    >;
    private enteWorkers: Array<any>;

    constructor(token: string, userID: number, concurrency?: number) {
        this.token = token;
        this.userID = userID;

        this.outOfSyncFiles = [];
        this.nSyncedFiles = 0;

        this.concurrency = concurrency ?? getConcurrency();

        log.info("Using concurrency: ", this.concurrency);
        // timeout is added on downloads
        // timeout on queue will keep the operation open till worker is terminated
        this.syncQueue = new PQueue({ concurrency: this.concurrency });
        logQueueStats(this.syncQueue, "sync");
        // this.downloadQueue = new PQueue({ concurrency: 1 });
        // logQueueStats(this.downloadQueue, 'download');

        this.comlinkCryptoWorker = new Array(this.concurrency);
        this.enteWorkers = new Array(this.concurrency);
    }

    public async getEnteWorker(id: number): Promise<any> {
        const wid = id % this.enteWorkers.length;
        console.log("getEnteWorker: ", id, wid);
        if (!this.enteWorkers[wid]) {
            this.comlinkCryptoWorker[wid] = getDedicatedCryptoWorker();
            this.enteWorkers[wid] = await this.comlinkCryptoWorker[wid].remote;
        }

        return this.enteWorkers[wid];
    }

    public async dispose() {
        this.localFilesMap = undefined;
        await this.syncQueue.onIdle();
        this.syncQueue.removeAllListeners();
        for (const enteComlinkWorker of this.comlinkCryptoWorker) {
            enteComlinkWorker?.terminate();
        }
    }
}

export const getConcurrency = () =>
    haveWindow() && Math.max(2, Math.ceil(navigator.hardwareConcurrency / 2));

class MachineLearningService {
    private localSyncContext: Promise<MLSyncContext>;
    private syncContext: Promise<MLSyncContext>;

    public async sync(token: string, userID: number): Promise<boolean> {
        if (!token) {
            throw Error("Token needed by ml service to sync file");
        }

        const syncContext = await this.getSyncContext(token, userID);

        await this.syncLocalFiles(syncContext);

        await this.getOutOfSyncFiles(syncContext);

        if (syncContext.outOfSyncFiles.length > 0) {
            await this.syncFiles(syncContext);
        }

        const error = syncContext.error;
        const nOutOfSyncFiles = syncContext.outOfSyncFiles.length;
        return !error && nOutOfSyncFiles > 0;
    }

    public async regenerateFaceCrop(faceID: string) {
        return regenerateFaceCrop(faceID);
    }

    private newMlData(fileId: number) {
        return {
            fileId,
            mlVersion: 0,
            errorCount: 0,
        } as MlFileData;
    }

    private async getLocalFilesMap(syncContext: MLSyncContext) {
        if (!syncContext.localFilesMap) {
            const localFiles = await getLocalFiles();

            const personalFiles = localFiles.filter(
                (f) => f.ownerID === syncContext.userID,
            );
            syncContext.localFilesMap = new Map<number, EnteFile>();
            personalFiles.forEach((f) =>
                syncContext.localFilesMap.set(f.id, f),
            );
        }

        return syncContext.localFilesMap;
    }

    private async syncLocalFiles(syncContext: MLSyncContext) {
        const startTime = Date.now();
        const localFilesMap = await this.getLocalFilesMap(syncContext);

        const db = await mlIDbStorage.db;
        const tx = db.transaction("files", "readwrite");
        const mlFileIdsArr = await mlIDbStorage.getAllFileIdsForUpdate(tx);
        const mlFileIds = new Set<number>();
        mlFileIdsArr.forEach((mlFileId) => mlFileIds.add(mlFileId));

        const newFileIds: Array<number> = [];
        for (const localFileId of localFilesMap.keys()) {
            if (!mlFileIds.has(localFileId)) {
                newFileIds.push(localFileId);
            }
        }

        let updated = false;
        if (newFileIds.length > 0) {
            log.info("newFiles: ", newFileIds.length);
            const newFiles = newFileIds.map((fileId) => this.newMlData(fileId));
            await mlIDbStorage.putAllFiles(newFiles, tx);
            updated = true;
        }

        const removedFileIds: Array<number> = [];
        for (const mlFileId of mlFileIds) {
            if (!localFilesMap.has(mlFileId)) {
                removedFileIds.push(mlFileId);
            }
        }

        if (removedFileIds.length > 0) {
            log.info("removedFiles: ", removedFileIds.length);
            await mlIDbStorage.removeAllFiles(removedFileIds, tx);
            updated = true;
        }

        await tx.done;

        if (updated) {
            // TODO: should do in same transaction
            await mlIDbStorage.incrementIndexVersion("files");
        }

        log.info("syncLocalFiles", Date.now() - startTime, "ms");
    }

    private async getOutOfSyncFiles(syncContext: MLSyncContext) {
        const startTime = Date.now();
        const fileIds = await mlIDbStorage.getFileIds(
            batchSize,
            defaultMLVersion,
            MAX_ML_SYNC_ERROR_COUNT,
        );

        log.info("fileIds: ", JSON.stringify(fileIds));

        const localFilesMap = await this.getLocalFilesMap(syncContext);
        syncContext.outOfSyncFiles = fileIds.map((fileId) =>
            localFilesMap.get(fileId),
        );
        log.info("getOutOfSyncFiles", Date.now() - startTime, "ms");
    }

    private async syncFiles(syncContext: MLSyncContext) {
        try {
            const functions = syncContext.outOfSyncFiles.map(
                (outOfSyncfile) => async () => {
                    await this.syncFileWithErrorHandler(
                        syncContext,
                        outOfSyncfile,
                    );
                    // TODO: just store file and faces count in syncContext
                },
            );
            syncContext.syncQueue.on("error", () => {
                syncContext.syncQueue.clear();
            });
            await syncContext.syncQueue.addAll(functions);
        } catch (error) {
            console.error("Error in sync job: ", error);
            syncContext.error = error;
        }
        await syncContext.syncQueue.onIdle();

        // TODO: In case syncJob has to use multiple ml workers
        // do in same transaction with each file update
        // or keep in files store itself
        await mlIDbStorage.incrementIndexVersion("files");
        // await this.disposeMLModels();
    }

    private async getSyncContext(token: string, userID: number) {
        if (!this.syncContext) {
            log.info("Creating syncContext");

            // TODO-ML(MR): Keep as promise for now.
            this.syncContext = new Promise((resolve) => {
                resolve(new MLSyncContext(token, userID));
            });
        } else {
            log.info("reusing existing syncContext");
        }
        return this.syncContext;
    }

    private async getLocalSyncContext(token: string, userID: number) {
        // TODO-ML(MR): This is updating the file ML version. verify.
        if (!this.localSyncContext) {
            log.info("Creating localSyncContext");
            // TODO-ML(MR):
            this.localSyncContext = new Promise((resolve) => {
                resolve(new MLSyncContext(token, userID));
            });
        } else {
            log.info("reusing existing localSyncContext");
        }
        return this.localSyncContext;
    }

    public async closeLocalSyncContext() {
        if (this.localSyncContext) {
            log.info("Closing localSyncContext");
            const syncContext = await this.localSyncContext;
            await syncContext.dispose();
            this.localSyncContext = undefined;
        }
    }

    public async syncLocalFile(
        token: string,
        userID: number,
        enteFile: EnteFile,
        localFile?: globalThis.File,
    ) {
        const syncContext = await this.getLocalSyncContext(token, userID);

        try {
            await this.syncFileWithErrorHandler(
                syncContext,
                enteFile,
                localFile,
            );

            if (syncContext.nSyncedFiles >= batchSize) {
                await this.closeLocalSyncContext();
            }
            // await syncContext.dispose();
        } catch (e) {
            console.error("Error while syncing local file: ", enteFile.id, e);
        }
    }

    private async syncFileWithErrorHandler(
        syncContext: MLSyncContext,
        enteFile: EnteFile,
        localFile?: globalThis.File,
    ) {
        try {
            console.log(
                `Indexing ${enteFile.title ?? "<untitled>"} ${enteFile.id}`,
            );
            const mlFileData = await this.syncFile(enteFile, localFile);
            syncContext.nSyncedFiles += 1;
            return mlFileData;
        } catch (e) {
            log.error("ML syncFile failed", e);
            let error = e;
            console.error(
                "Error in ml sync, fileId: ",
                enteFile.id,
                "name: ",
                enteFile.metadata.title,
                error,
            );
            if ("status" in error) {
                const parsedMessage = parseUploadErrorCodes(error);
                error = parsedMessage;
            }
            // TODO: throw errors not related to specific file
            // sync job run should stop after these errors
            // don't persist these errors against file,
            // can include indexeddb/cache errors too
            switch (error.message) {
                case CustomError.SESSION_EXPIRED:
                case CustomError.NETWORK_ERROR:
                    throw error;
            }

            await this.persistMLFileSyncError(enteFile, error);
            syncContext.nSyncedFiles += 1;
        }
    }

    private async syncFile(enteFile: EnteFile, localFile?: globalThis.File) {
        const oldMlFile = await this.getMLFileData(enteFile.id);
        if (oldMlFile && oldMlFile.mlVersion) {
            return oldMlFile;
        }

        const newMlFile = await indexFaces(enteFile, localFile);
        await putFaceEmbedding(enteFile, newMlFile);
        await mlIDbStorage.putFile(newMlFile);
        return newMlFile;
    }

    private async getMLFileData(fileId: number) {
        return mlIDbStorage.getFile(fileId);
    }

    private async persistMLFileSyncError(enteFile: EnteFile, e: Error) {
        try {
            await mlIDbStorage.upsertFileInTx(enteFile.id, (mlFileData) => {
                if (!mlFileData) {
                    mlFileData = this.newMlData(enteFile.id);
                }
                mlFileData.errorCount = (mlFileData.errorCount || 0) + 1;
                console.error(`lastError for ${enteFile.id}`, e);

                return mlFileData;
            });
        } catch (e) {
            // TODO: logError or stop sync job after most of the requests are failed
            console.error("Error while storing ml sync error", e);
        }
    }
}

export default new MachineLearningService();

export function logQueueStats(queue: PQueue, name: string) {
    queue.on("active", () =>
        log.info(
            `queuestats: ${name}: Active, Size: ${queue.size} Pending: ${queue.pending}`,
        ),
    );
    queue.on("idle", () => log.info(`queuestats: ${name}: Idle`));
    queue.on("error", (error) =>
        console.error(`queuestats: ${name}: Error, `, error),
    );
}

export const regenerateFaceCrop = async (faceID: string) => {
    const fileID = Number(faceID.split("-")[0]);
    const personFace = await mlIDbStorage.getFace(fileID, faceID);
    if (!personFace) {
        throw Error("Face not found");
    }

    const file = await getLocalFile(personFace.fileId);
    const imageBitmap = await fetchImageBitmap(file);
    return await saveFaceCrop(imageBitmap, personFace);
};
