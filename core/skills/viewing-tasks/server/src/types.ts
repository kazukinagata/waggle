export interface Task {
  id: string;
  title: string;
  description: string;
  acceptanceCriteria: string;
  status: "Backlog" | "Ready" | "In Progress" | "In Review" | "Done" | "Blocked" | "Cancelled";
  blockedBy: string[];
  priority: "Urgent" | "High" | "Medium" | "Low" | null;
  executor: "claude-desktop" | "cli" | "cowork" | "human" | null;
  requiresReview: boolean;
  executionPlan: string;
  workingDirectory: string;
  sessionReference: string;
  dispatchedAt: string | null;
  agentOutput: string;
  errorMessage: string;
  // Extended fields (optional)
  context: string;
  artifacts: string;
  repository: string | null;
  startDate: string | null;
  dueDate: string | null;
  tags: string[];
  parentTaskId: string | null;
  project: string | null;
  team: string | null;
  assignee: { id: string; name: string }[];
  // File descriptors (references to hosted bytes). Notion-hosted URLs are signed
  // and expire ~1h, so consumers needing a fresh URL re-fetch from the provider.
  attachments: { url: string; name: string; mime_type?: string; size?: number }[];
  acknowledgedAt: string | null;
  createdAt: string | null;
  url: string;
}

export interface TasksResponse {
  tasks: Task[];
  updatedAt: string;
}
