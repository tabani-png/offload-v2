import { startFromEnv } from "./start.ts";

/** `offload broker`: bun services/broker/src/main.ts */
const running = await startFromEnv();
const shutdown = () => void running.stop().finally(() => process.exit(0));
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
