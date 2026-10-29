import type { EmailSender } from "../../ports";

export interface ResendOptions {
  apiKey: string;
  /** For example `Running Plan <no-reply@yourdomain.com>`; the domain must be verified in Resend. */
  from: string;
  fetch?: typeof fetch;
}

/** Sends the sign-in code through the Resend HTTP API. Plain `fetch`, so it runs on Workers and Node. */
export class ResendEmailSender implements EmailSender {
  private readonly fetcher: typeof fetch;

  constructor(private readonly options: ResendOptions) {
    this.fetcher = options.fetch ?? fetch;
  }

  async sendCode(to: string, code: string): Promise<void> {
    const response = await this.fetcher("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${this.options.apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: this.options.from,
        to: [to],
        subject: `Your Running Plan code is ${code}`,
        text: `Your sign-in code is ${code}. It expires in 10 minutes. If you did not ask for it, you can ignore this email.`,
      }),
    });
    // The status only: the body can echo the address, and neither the key nor the code belongs in an error.
    if (!response.ok) throw new Error(`Resend refused the email (HTTP ${response.status})`);
  }
}
