import { MemoryAuthStore, MemoryRateLimiter } from "../src/adapters/memory";
import { authStoreContract, rateLimiterContract } from "./support/auth-store-contract";

authStoreContract("memory", async () => ({ store: new MemoryAuthStore(), reset: async () => {} }));
rateLimiterContract("memory", async () => ({ limiter: new MemoryRateLimiter(), reset: async () => {} }));
