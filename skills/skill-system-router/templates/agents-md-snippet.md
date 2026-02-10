## Skill System

This project uses a skill system for agent orchestration, behavioral profiles, and persistent memory.

### Skills Directory
`{SKILLS_DIR}`

### How to Use
1. **Router**: Load `skill-system-router` to orchestrate skills. It reads skill manifests and executes operations.
2. **Soul**: Load `skill-system-soul` to adopt a behavioral profile. Available: `balanced` (default), `creative`, `strict`, `talkative`.
3. **Memory**: Use `agent_memories` (PostgreSQL) for persistent cross-session memory. See `skill-system-memory`.
4. **Insight**: After non-trivial sessions, suggest an insight pass to learn user preferences. See `skill-system-insight`.

### Quick Reference
- Discover skills: read `{SKILLS_DIR}/skills-index.json` or run `build-index.sh`
- Load a soul: read `{SKILLS_DIR}/skill-system-soul/profiles/<name>.md`
- Store memory: `SELECT store_memory(type, category, tags, title, content, metadata, agent_id, session_id, importance);`
- Search memory: `SELECT * FROM search_memories('query');`
- Extract insight: follow `{SKILLS_DIR}/skill-system-insight/scripts/extract-facets.md`

### User Soul State
If a personalized profile exists at `{SKILLS_DIR}/skill-system-soul/profiles/<user>.md`, prefer it over `balanced.md`.
Check `agent_memories` for `category='soul-state'` to see the user's dual matrix.

### Insight Suggestion
After completing a non-trivial session, consider asking:
> "Want me to run an insight pass on this session? It helps me learn your preferences for better collaboration."
