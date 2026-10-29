import { describe, expect, it } from "vitest";
import { ResendEmailSender } from "../src/adapters/resend/resend-email";

describe("ResendEmailSender", () => {
  it("posts the code to the Resend API with the key and sender", async () => {
    const calls: { url: string; init: RequestInit }[] = [];
    const fetcher = (async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return new Response('{"id":"x"}', { status: 200 });
    }) as unknown as typeof fetch;
    const sender = new ResendEmailSender({ apiKey: "re_test", from: "Running Plan <no-reply@example.com>", fetch: fetcher });
    await sender.sendCode("runner@example.com", "123456");
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe("https://api.resend.com/emails");
    expect((calls[0]!.init.headers as Record<string, string>).Authorization).toBe("Bearer re_test");
    const body = JSON.parse(calls[0]!.init.body as string);
    expect(body).toMatchObject({ from: "Running Plan <no-reply@example.com>", to: ["runner@example.com"] });
    expect(body.text).toContain("123456");
    expect(body.subject).toContain("123456");
  });
  it("throws when Resend refuses, without leaking the key or the code", async () => {
    const fetcher = (async () => new Response("nope", { status: 422 })) as unknown as typeof fetch;
    const sender = new ResendEmailSender({ apiKey: "re_secret", from: "a@example.com", fetch: fetcher });
    const error = await sender.sendCode("runner@example.com", "654321").catch((e: Error) => e);
    expect(error).toBeInstanceOf(Error);
    expect((error as Error).message).toContain("422");
    expect((error as Error).message).not.toContain("re_secret");
    expect((error as Error).message).not.toContain("654321");
  });
});
