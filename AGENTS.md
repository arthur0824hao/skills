## Skill System

This project uses a skill system for agent orchestration, behavioral profiles, and persistent memory.

### Skills Directory
`C:\Users\arthu\skill\skills`

### How to Use
1. **Router**: Load `skill-system-router` to orchestrate skills. It reads skill manifests and executes operations.
2. **Soul**: Load `skill-system-soul` to adopt a behavioral profile. Available: `balanced` (default), `creative`, `strict`, `talkative`.
3. **Memory**: Use `agent_memories` (PostgreSQL) for persistent cross-session memory. See `skill-system-memory`.
4. **Insight**: After non-trivial sessions, suggest an insight pass to learn user preferences. See `skill-system-insight`.
5. **Workflow**: Load `skill-system-workflow` to plan multi-step work as DAGs with Mermaid visualization. Includes reusable recipes for common patterns (debug, feature, session start/end).
6. **Evolution**: Load `skill-system-evolution` to evolve soul profiles and workflow recipes based on accumulated insight data. Version-controlled with rollback support.

### Quick Reference
- Discover skills: read `C:\Users\arthu\skill\skills/skills-index.json` or run `build-index.sh`
- Load a soul: read `C:\Users\arthu\skill\skills/skill-system-soul/profiles/<name>.md`
- Store memory: `SELECT store_memory(type, category, tags, title, content, metadata, agent_id, session_id, importance);`
- Search memory: `SELECT * FROM search_memories('query');`
- Extract insight: follow `C:\Users\arthu\skill\skills/skill-system-insight/scripts/extract-facets.md`
- Plan workflow: follow `C:\Users\arthu\skill\skills/skill-system-workflow/scripts/plan-and-visualize.md`
- Evolve soul: follow `C:\Users\arthu\skill\skills/skill-system-evolution/scripts/evolve-soul.md`
- List versions: follow `C:\Users\arthu\skill\skills/skill-system-evolution/scripts/list-versions.md`

### User Soul State
If a personalized profile exists at `C:\Users\arthu\skill\skills/skill-system-soul/profiles/<user>.md`, prefer it over `balanced.md`.
Check `agent_memories` for `category='soul-state'` to see the user's dual matrix.

### Insight Suggestion
After completing a non-trivial session, consider asking:
> "Want me to run an insight pass on this session? It helps me learn your preferences for better collaboration."
