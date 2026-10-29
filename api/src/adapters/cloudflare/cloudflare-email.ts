import type { EmailSender } from "../../ports";

/** The part of a Cloudflare `send_email` binding this adapter uses. */
export interface SendBinding {
  send(message: { from: string | { email: string; name?: string }; to: string; subject: string; text: string }): Promise<unknown>;
}

export interface CloudflareEmailOptions {
  binding: SendBinding;
  /** For example `Running Plan <no-reply@yourdomain.com>`; the domain must be onboarded to Cloudflare Email Sending. */
  from: string;
}

const NAMED_ADDRESS = /^\s*(.*?)\s*<([^<>]+)>\s*$/;

/** Sends the sign-in code through Cloudflare Email Sending (the `send_email` Workers binding). */
export class CloudflareEmailSender implements EmailSender {
  private readonly from: string | { email: string; name?: string };

  constructor(private readonly options: CloudflareEmailOptions) {
    const named = NAMED_ADDRESS.exec(options.from);
    this.from = named && named[1] ? { email: named[2]!, name: named[1] } : (named?.[2] ?? options.from);
  }

  async sendCode(to: string, code: string): Promise<void> {
    try {
      await this.options.binding.send({
        from: this.from,
        to,
        subject: `Your Running Plan code is ${code}`,
        text: `Your sign-in code is ${code}. It expires in 10 minutes. If you did not ask for it, you can ignore this email.`,
      });
    } catch {
      // Binding errors can echo the address; neither it nor the code belongs in an error.
      throw new Error("Cloudflare Email Sending refused the email");
    }
  }
}
