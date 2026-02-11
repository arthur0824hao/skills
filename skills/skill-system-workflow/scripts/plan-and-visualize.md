# Procedure: Plan And Visualize Workflow

Goal: Given a `goal` (and optional `context`), produce:

1) A `workflow-dag.yaml` document (conforming to `schema/workflow-dag.yaml`)
2) A Mermaid diagram (`flowchart TD`) that visualizes the DAG (conforming to SKILL.md conventions)

This is an agent-executed procedure. It is NOT executable code.

## Step 0: Inputs and outputs

Inputs:

- goal: string
- context: optional string

Outputs:

- dag_yaml: YAML text for the workflow DAG
- mermaid: Mermaid `flowchart TD` text

## Step 1: Read all recipes

1. Enumerate all files in `recipes/`.
2. For each recipe file:
   - Read the YAML
   - Extract `name`, `description`, and `trigger_patterns`

## Step 2: Match goal against trigger_patterns

1. Normalize goal text (lowercase, trim whitespace).
2. For each recipe, check if the goal contains any phrase in `trigger_patterns`.
3. Choose the best match:
   - Prefer the recipe with the most specific phrase match (longer phrase wins).
   - If ties: choose the recipe with the highest number of matched patterns.
4. If no recipe matches, proceed to Step 4.

## Step 3: If match: use recipe as base, customize

1. Copy the recipe's waves/tasks into a new DAG structure.
2. Fill in DAG header fields:
   - `schema_version: 1`
   - `title: "Workflow DAG"`
   - `id`: generate a unique id (example: `wf_YYYY-MM-DD_<shortslug>`)
   - `goal`: the input goal string
   - `created_at`: current ISO 8601 timestamp
3. Customize each task description for the specific goal:
   - Replace `{goal}` placeholder if present.
   - Add any relevant file paths, commands, constraints from `context`.
   - Keep tasks atomic and verifiable.
4. Initialize statuses:
   - Set each task `status: pending`.

## Step 4: If no match: generate custom DAG

1. Use `prompts/plan-workflow.md` as the planning prompt.
2. Provide it the `goal`, `context`, and the available agent types.
3. Produce a one-pass DAG YAML result.

## Step 5: Validate DAG against schema

Validate the DAG YAML against `schema/workflow-dag.yaml`:

1. Ensure required fields exist: `id`, `goal`, `created_at`, `waves`.
2. Ensure each wave has `name`, `parallel`, `tasks`.
3. Ensure each task has:
   - `id`, `name`, `agent_type`, `description`, `depends_on`, `status`, `verification`, `skills`
4. Ensure `depends_on`:
   - references only task ids from earlier waves
   - contains no cycles
5. Ensure `agent_type` and `status` values are valid enums.

If validation fails, fix the DAG YAML until it conforms.

## Step 6: Generate Mermaid flowchart TD

Generate a Mermaid diagram using these conventions:

Diagram header:

- Must start with `flowchart TD`
- One Mermaid `subgraph` per wave
- One node per task

Wave subgraphs:

- Use one subgraph per wave, in order:
  - `subgraph waveN[<wave name>]`
  - where `N` is 1-based index in `waves`

Nodes:

- For each task, create a rounded-rectangle node:
  - `task_id(["<agent_type>\\n<task name>"])`

Edges:

- For each task with `depends_on`, add edges from each dependency:
  - `dep_task_id --> task_id`

Status styling:

1. Include these class definitions exactly:

```
classDef pending fill:#fef3c7,stroke:#f59e0b,stroke-width:2px,color:#92400e
classDef running fill:#dbeafe,stroke:#3b82f6,stroke-width:2px,stroke-dasharray: 5 5,color:#1e40af
classDef done fill:#d1fae5,stroke:#10b981,stroke-width:2px,color:#065f46
classDef failed fill:#fee2e2,stroke:#ef4444,stroke-width:3px,color:#991b1b
```

2. Apply the appropriate class to each task node based on `status`:

- `class <task_id> pending`
- `class <task_id> running`
- `class <task_id> done`
- `class <task_id> failed`

## Step 7: Return outputs

Return BOTH artifacts:

1. The final DAG YAML (as YAML text)
2. The final Mermaid diagram (as Mermaid text)

Do not include extra commentary that would confuse downstream parsing.
