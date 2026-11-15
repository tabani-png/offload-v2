import { BROKER_ERROR_STATUS, type BrokerErrorCode } from "@offload/contracts/src/broker/index.ts";

/** An error the broker answers with: a closed code (contracts) and a message that never holds a secret. */
export class BrokerError extends Error {
  readonly code: BrokerErrorCode;
  constructor(code: BrokerErrorCode, message: string) {
    super(message);
    this.name = "BrokerError";
    this.code = code;
  }
  get status(): number {
    return BROKER_ERROR_STATUS[this.code];
  }
}
