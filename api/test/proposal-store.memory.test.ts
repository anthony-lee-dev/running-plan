import { MemoryActivityStore, MemoryAuthStore, MemoryCheckInStore, MemoryMatchStore, MemoryPlanStore, MemoryProposalStore } from "../src/adapters/memory";
import { proposalStoreContract } from "./support/proposal-store-contract";

proposalStoreContract("memory", async () => {
  const auth = new MemoryAuthStore();
  const plans = new MemoryPlanStore(auth);
  const activities = new MemoryActivityStore(auth);
  const checkIns = new MemoryCheckInStore(auth, plans);
  const matches = new MemoryMatchStore(auth, plans, activities);
  return { store: new MemoryProposalStore(auth, plans, checkIns), plans, checkIns, matches, activities, auth, reset: async () => {} };
});
