/// Worker entry point. Side-effect imports register both the compile and
/// group-deadline BullMQ Worker instances. Kept as a single process for MVP
/// — split into two services later if either consumer becomes a bottleneck.
import "./compile.js";
import "./deadline.js";

console.log("worker started: compile + group-deadline consumers active");
