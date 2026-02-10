# Bootstrap (First Run Only)

This procedure embeds the Skill System into a project's `AGENTS.md` so future sessions automatically know how to use skills.

Precondition: You only need to do this if the project's `AGENTS.md` does **not** contain a `## Skill System` section.

## 1) Find the project's AGENTS.md

Search from the current working directory upward (max 3 parent levels). Check these paths in order and pick the first one that exists:

- `./AGENTS.md`
- `../AGENTS.md`
- `../../AGENTS.md`
- `../../../AGENTS.md`

If none exists, create `./AGENTS.md` in the current working directory.

## 2) Confirm bootstrap is needed

Open the chosen `AGENTS.md` and search for the literal header line:

`## Skill System`

- If it exists anywhere in the file: stop (already bootstrapped).
- If it does not exist: continue.

## 3) Read the snippet template

Open this file:

`templates/agents-md-snippet.md`

## 4) Replace `{SKILLS_DIR}` with the absolute skills directory path

In the snippet content, replace the literal placeholder `{SKILLS_DIR}` with the absolute path to the skills directory for this installation.

Definition: the skills directory is the folder that contains `skills-index.json` and contains sibling skill folders (including this one).

In a standard layout, it is the parent directory of this skill folder (`skill-system-router`).

Example on Windows:

`C:\Users\arthu\skill\skills`

## 5) Append the snippet to AGENTS.md

Append the fully-substituted snippet to the end of `AGENTS.md`.

Append rules:

- Ensure there is at least one blank line before the appended `## Skill System` header.
- Do not modify or delete any existing content.

## 6) Tell the user what was added

Report:

- The `AGENTS.md` path that was updated/created.
- That you added a `## Skill System` section.
- The resolved skills directory path you embedded.
