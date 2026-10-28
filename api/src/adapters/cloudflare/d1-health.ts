import type { HealthProbe } from "../../ports";

export class D1HealthProbe implements HealthProbe {
  constructor(private readonly db: D1Database) {}

  async check(): Promise<boolean> {
    try {
      const row = await this.db.prepare("SELECT 1 AS ok").first<{ ok: number }>();
      return row?.ok === 1;
    } catch {
      return false;
    }
  }
}
