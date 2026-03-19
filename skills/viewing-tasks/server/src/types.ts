export interface Task {
  id: string;
  title: string;
  description: string;
  acceptanceCriteria: string;
  status: "Backlog" | "Ready" | "In Progress" | "In Review" | "Done" | "Blocked";
  blockedBy: string[];
  priority: "Urgent" | "High" | "Medium" | "Low" | null;
  executor: "claude-desktop" | "cli" | "human" | null;
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
  dueDate: string | null;
  tags: string[];
  parentTaskId: string | null;
  project: string | null;
  team: string | null;
  assignees: { id: string; name: string }[];
  url: string;
  // Sprint fields (optional — present only when scrum is enabled)
  sprintId: string | null;
  sprintName: string | null;
  complexityScore: number | null;
  backlogOrder: number | null;
}

export interface TasksResponse {
  tasks: Task[];
  updatedAt: string;
}

export interface Sprint {
  id: string;
  name: string;
  goal: string;
  status: "Planning" | "Active" | "Completed" | "Closed";
  maxConcurrentAgents: number | null;
  velocity: number | null;
  url: string;
}

export interface SprintsResponse {
  sprints: Sprint[];
  currentSprintId: string | null;
  updatedAt: string;
}
