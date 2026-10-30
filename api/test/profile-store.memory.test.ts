import { MemoryAuthStore, MemoryProfileStore } from "../src/adapters/memory";
import { profileStoreContract } from "./support/profile-store-contract";

profileStoreContract("memory", async () => {
  const auth = new MemoryAuthStore();
  return { store: new MemoryProfileStore(auth), auth, reset: async () => {} };
});
