import { describe, it, expect } from "vitest";
import { EventBus } from "../src/sse.js";

describe("EventBus", () => {
  it("notifies subscribers on emit", async () => {
    const bus = new EventBus();
    const received: string[] = [];

    const unsubscribe = bus.subscribe((data) => {
      received.push(data);
    });

    bus.emit("update-1");
    bus.emit("update-2");

    expect(received).toEqual(["update-1", "update-2"]);

    unsubscribe();
    bus.emit("update-3");
    expect(received).toEqual(["update-1", "update-2"]);
  });

  it("supports multiple subscribers", () => {
    const bus = new EventBus();
    let count = 0;

    bus.subscribe(() => count++);
    bus.subscribe(() => count++);
    bus.emit("test");

    expect(count).toBe(2);
  });
});
