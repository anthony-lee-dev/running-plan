import { MemoryAuthStore, MemoryCheckInStore, MemoryPlanStore } from "../src/adapters/memory";
import { checkInStoreContract } from "./support/checkin-store-contract";

checkInStoreContract("memory", async () => {
  const auth = new MemoryAuthStore();
  const plans = new MemoryPlanStore(auth);
  return { store: new MemoryCheckInStore(auth, plans), plans, auth, reset: async () => {} };
});
