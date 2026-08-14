import { readConfig } from "./config.js";
import { createFitnessStore } from "./db.js";
import { createServer } from "./server.js";

const config = readConfig();
const store = createFitnessStore(config.databaseUrl);
const app = createServer(config, store);

app.listen(config.port, () => {
  console.log(`Robur API listening on ${config.port}`);
});
