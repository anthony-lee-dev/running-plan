import { describe, expect, it } from "vitest";
import { CloudflareEmailSender, type SendBinding } from "../src/adapters/cloudflare/cloudflare-email";

describe("CloudflareEmailSender", () => {
  it("sends the code through the send_email binding from the configured sender", async () => {
    const sent: unknown[] = [];
    const binding: SendBinding = { send: async (message) => void sent.push(message) };
    const sender = new CloudflareEmailSender({ binding, from: "Running Plan <no-reply@example.com>" });
    await sender.sendCode("runner@example.com", "123456");
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({ from: { email: "no-reply@example.com", name: "Running Plan" }, to: "runner@example.com" });
    const message = sent[0] as { subject: string; text: string };
    expect(message.subject).toContain("123456");
    expect(message.text).toContain("123456");
  });

  it("passes a plain sender address through as a string", async () => {
    const sent: { from: unknown }[] = [];
    const binding: SendBinding = { send: async (message) => void sent.push(message as { from: unknown }) };
    await new CloudflareEmailSender({ binding, from: "no-reply@example.com" }).sendCode("a@example.com", "1");
    expect(sent[0]!.from).toBe("no-reply@example.com");
  });

  it("throws a generic error when the binding fails, without leaking the code or the address", async () => {
    const binding: SendBinding = { send: async () => Promise.reject(new Error("E_SENDER_NOT_VERIFIED for runner@example.com 654321")) };
    const sender = new CloudflareEmailSender({ binding, from: "a@example.com" });
    const error = await sender.sendCode("runner@example.com", "654321").catch((e: Error) => e);
    expect(error).toBeInstanceOf(Error);
    expect((error as Error).message).not.toContain("654321");
    expect((error as Error).message).not.toContain("runner@example.com");
  });
});
