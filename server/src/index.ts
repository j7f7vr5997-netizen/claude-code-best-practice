import Fastify from "fastify";
import { registerMessageRoutes } from "./routes/messages.js";
import { registerAttemptRoutes } from "./routes/attempts.js";
import { registerGroupRoutes } from "./routes/groups.js";

const app = Fastify({ logger: true });

app.get("/healthz", async () => ({ ok: true }));

await registerMessageRoutes(app);
await registerAttemptRoutes(app);
await registerGroupRoutes(app);

const port = Number(process.env.PORT ?? 3000);
app.listen({ host: "0.0.0.0", port }).catch((err) => {
  app.log.error(err);
  process.exit(1);
});
