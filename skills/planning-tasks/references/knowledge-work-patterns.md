# Knowledge Work Patterns Reference

Reference framework for the knowledge-planning-agent. Derived from patterns in [knowledge-work-plugins](https://github.com/anthropics/knowledge-work-plugins).

## Progressive Clarification Framework

Don't dump all questions at once. Follow this sequence:

1. **Key discovery**: What is the core objective? Who is it for?
2. **Measurability**: What does success look like? What metrics?
3. **Foundation**: What's been tried? What constraints exist?
4. **Detail**: Edge cases, dependencies, risks

## Completeness Checklist for AC

Every task's AC should cover:

- Clear objective (measurable outcome, not vague aspiration)
- Scope boundaries (explicit goals + non-goals)
- Definition of done (testable: deliverable exists, approval obtained, metric met)
- Success metrics (how to verify completion)

## Quality Red Flags

Reject or challenge these in user input:

- **Vague language**: "fast", "intuitive", "seamless" without metrics
- **Missing recipient**: who is this for?
- **No deadline or time context**
- **No success criteria**: how will we know it's done?
- **Incomplete scope**: no explicit non-goals
- **Unexamined assumptions**: not validated against actual needs

## Domain-Specific Templates

### Marketing / Campaign

**AC Pattern**: Objective + Audience + KPI targets
```
- [ ] Campaign objective defined with measurable KPI (e.g., 500 signups)
- [ ] Target audience profile documented (demographics, pain points)
- [ ] Channel strategy selected with rationale
- [ ] Content calendar created (work backward from launch date)
- [ ] Success metrics and tracking method defined
```

**Plan Pattern**: Content calendar working backward from launch
```
1. Define objective and KPI targets
2. Profile target audience (segments, pain points, channel preferences)
3. Select channels with rationale
4. Create content calendar (backward from launch)
5. Produce content assets (blog: 3-5d, email: 2-3d, landing page: 5-7d)
6. Review with stakeholders
7. Launch and measure
```

### Documentation / Process

**AC Pattern**: RACI matrix + deliverable per step
```
- [ ] Process document created with Who/When/How/Output per step
- [ ] RACI matrix defined (Responsible/Accountable/Consulted/Informed)
- [ ] Exception scenarios documented
- [ ] Reviewed and approved by process owner
```

**Plan Pattern**: Who/When/How/Output per step
```
1. Interview stakeholders to map current process
2. Draft process document with steps, owners, and outputs
3. Define RACI matrix
4. Document exception handling
5. Review with process owner
6. Publish and communicate
```

### Research / Analysis

**AC Pattern**: Research question + methodology + deliverable format
```
- [ ] Research objectives defined
- [ ] Methodology selected (interviews: 5-8, survey: 100+)
- [ ] Data collected per methodology
- [ ] Synthesis report with themes and recommendations created
- [ ] Findings shared with stakeholders
```

**Plan Pattern**: Hypothesis → Data collection → Synthesis → Report
```
1. Define research questions and hypothesis
2. Select methodology and plan timeline
3. Recruit participants / prepare data sources
4. Collect data (interviews, surveys, analysis)
5. Synthesize findings (thematic clustering)
6. Create report with recommendations
7. Present to stakeholders
```

### Coordination / Meeting

**AC Pattern**: Agenda items + expected outcomes + next steps
```
- [ ] Agenda prepared and shared with participants
- [ ] Meeting conducted within scheduled time
- [ ] Decisions and action items recorded
- [ ] Follow-up items assigned with owners and deadlines
- [ ] Notes shared with participants
```

**Plan Pattern**: Prep → Execute → Record → Follow-up
```
1. Prepare agenda with objectives and time allocation
2. Share agenda with participants (at least 24h before)
3. Conduct meeting, facilitate discussion
4. Record decisions and action items during meeting
5. Share notes and action items within 24h
6. Follow up on action items by deadline
```

### Design / Architecture

**AC Pattern**: ADR format — Context + Options + Trade-offs + Decision
```
- [ ] Architecture Decision Record (ADR) created
- [ ] At least 2 alternative options documented with trade-offs
- [ ] Decision rationale documented
- [ ] Implementation implications noted
- [ ] Reviewed by technical stakeholders
```

**Plan Pattern**: Decision record + implementation plan
```
1. Document context and constraints
2. Research and document 2+ alternative approaches
3. Analyze trade-offs (performance, cost, maintainability)
4. Draft recommendation with rationale
5. Review with stakeholders
6. Record final decision in ADR
7. Create implementation plan
```

### Operations / HR

**AC Pattern**: Pipeline stages with decision criteria
```
- [ ] Workflow stages defined with entry/exit criteria
- [ ] Decision criteria documented per stage
- [ ] Metrics and tracking method defined
- [ ] Process documented and shared with team
```

**Plan Pattern**: Sequential stages with checkpoints
```
1. Define workflow stages and transitions
2. Set entry/exit criteria per stage
3. Define metrics to track
4. Document process
5. Train team on new process
6. Monitor and iterate
```

## Evidence Hierarchy

When validating or synthesizing plans:

1. **Behavioral data** (what people actually did) > stated preferences
2. **Multiple sources** (triangulation) > single source
3. **Specific evidence** (exact metrics, quotes) > paraphrasing
4. **Explicit confidence levels** (high/medium/low) > unstated certainty

## Dependency Framework

For any multi-step plan:

- **Categorize dependencies**: Technical, team, external, knowledge, sequential
- **Assign owners** for each dependency
- **Set "need by" dates** for each blocker
- **Track escalation triggers** (SLA, scope changes, new signals)
