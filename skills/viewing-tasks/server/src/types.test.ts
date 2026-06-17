import { describe, it, expectTypeOf } from "vitest";
import type { Task, TasksResponse } from "./types.js";

describe("Task type — Core fields", () => {
  it("executor replaces agentType and accepts correct values", () => {
    expectTypeOf<Task["executor"]>().toEqualTypeOf<
      "claude-desktop" | "cli" | "cowork" | "human" | null
    >();
  });

  it("agentType does not exist on Task", () => {
    type HasAgentType = "agentType" extends keyof Task ? true : false;
    expectTypeOf<HasAgentType>().toEqualTypeOf<false>();
  });

  it("requiresReview is a non-optional boolean", () => {
    expectTypeOf<Task["requiresReview"]>().toEqualTypeOf<boolean>();
  });

  it("status includes Blocked", () => {
    expectTypeOf<Task["status"]>().toEqualTypeOf<
      "Backlog" | "Ready" | "In Progress" | "In Review" | "Done" | "Blocked" | "Cancelled"
    >();
  });

  it("executionPlan is a string (not optional)", () => {
    expectTypeOf<Task["executionPlan"]>().toEqualTypeOf<string>();
  });

  it("workingDirectory is a string (not optional)", () => {
    expectTypeOf<Task["workingDirectory"]>().toEqualTypeOf<string>();
  });

  it("sessionReference is a string (not optional)", () => {
    expectTypeOf<Task["sessionReference"]>().toEqualTypeOf<string>();
  });

  it("dispatchedAt is nullable string", () => {
    expectTypeOf<Task["dispatchedAt"]>().toEqualTypeOf<string | null>();
  });

  it("errorMessage is a string separate from agentOutput", () => {
    expectTypeOf<Task["errorMessage"]>().toEqualTypeOf<string>();
    expectTypeOf<Task["agentOutput"]>().toEqualTypeOf<string>();
    // Both must be present and independently typed
    type HasBoth = "errorMessage" extends keyof Task
      ? "agentOutput" extends keyof Task
        ? true
        : false
      : false;
    expectTypeOf<HasBoth>().toEqualTypeOf<true>();
  });
});

describe("Task type — removed fields", () => {
  it("reporter does not exist on Task", () => {
    type HasReporter = "reporter" extends keyof Task ? true : false;
    expectTypeOf<HasReporter>().toEqualTypeOf<false>();
  });

  it("reviewers does not exist on Task", () => {
    type HasReviewers = "reviewers" extends keyof Task ? true : false;
    expectTypeOf<HasReviewers>().toEqualTypeOf<false>();
  });

  it("estimate does not exist on Task", () => {
    type HasEstimate = "estimate" extends keyof Task ? true : false;
    expectTypeOf<HasEstimate>().toEqualTypeOf<false>();
  });
});

describe("Task type — Extended fields", () => {
  it("artifacts is rich_text (string, not url string union)", () => {
    expectTypeOf<Task["artifacts"]>().toEqualTypeOf<string>();
  });

  it("repository is nullable URL string", () => {
    expectTypeOf<Task["repository"]>().toEqualTypeOf<string | null>();
  });

  it("startDate is nullable string", () => {
    expectTypeOf<Task["startDate"]>().toEqualTypeOf<string | null>();
  });

  it("dueDate is nullable string", () => {
    expectTypeOf<Task["dueDate"]>().toEqualTypeOf<string | null>();
  });

  it("attachments is an array of file descriptors", () => {
    expectTypeOf<Task["attachments"]>().toEqualTypeOf<
      { url: string; name: string; mime_type?: string; size?: number }[]
    >();
  });
});

describe("TasksResponse", () => {
  it("contains tasks array and updatedAt string", () => {
    expectTypeOf<TasksResponse["tasks"]>().toEqualTypeOf<Task[]>();
    expectTypeOf<TasksResponse["updatedAt"]>().toEqualTypeOf<string>();
  });
});
