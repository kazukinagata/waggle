/* Waggle — Task Detail Panel */

(function () {
  'use strict';

  var W = window.Waggle;
  if (!W) return;

  // Inject panel DOM
  var overlay = document.createElement('div');
  overlay.className = 'detail-overlay';
  overlay.id = 'detail-overlay';
  document.body.appendChild(overlay);

  var panel = document.createElement('aside');
  panel.className = 'detail-panel';
  panel.id = 'detail-panel';
  document.body.appendChild(panel);

  overlay.addEventListener('click', closeDetail);

  function executorClass(e) {
    return { cli: 'e-cli', 'claude-desktop': 'e-desktop', cowork: 'e-cowork', human: 'e-human' }[e] || '';
  }

  function executorLabel(e) {
    return { cli: 'CLI', 'claude-desktop': 'Claude Desktop', cowork: 'Cowork', human: 'Human' }[e] || e;
  }

  function findTask(id) {
    return W.allTasks.find(function (t) { return t.id === id; });
  }

  function openDetail(taskId) {
    var t = findTask(taskId);
    if (!t) return;

    // Copy ID
    navigator.clipboard.writeText(t.id).catch(function () {});
    W.showToast('ID copied: ' + t.id.slice(0, 8) + '...');

    var hierarchy = W.buildHierarchy(W.allTasks);
    var html = '';

    // Header
    html += '<div class="detail-header">';
    html += '<div class="detail-actions">';
    if (t.url) {
      html += '<a href="' + W.esc(t.url) + '" target="_blank" rel="noopener" class="detail-action-btn primary">Open in source</a>';
    }
    html += '<button class="detail-action-btn" onclick="Waggle.copyId(\'' + t.id + '\')">Copy ID</button>';
    html += '<button class="detail-close-btn" onclick="Waggle.closeDetail()" title="Close (Esc)">&times;</button>';
    html += '</div>';
    html += '<div class="detail-title">' + W.esc(t.title) + '</div>';
    html += '</div>';

    // Body
    html += '<div class="detail-body">';

    // Properties
    html += '<div class="detail-properties">';

    // Status
    html += '<div class="detail-prop">';
    html += '<span class="detail-prop-label">Status</span>';
    html += '<span class="detail-prop-value"><span class="badge ' + W.statusClass(t.status) + '">' + W.esc(t.status) + '</span></span>';
    html += '</div>';

    // Priority
    html += '<div class="detail-prop">';
    html += '<span class="detail-prop-label">Priority</span>';
    html += '<span class="detail-prop-value">' + (t.priority ? '<span class="badge ' + W.priorityClass(t.priority) + '">' + W.esc(t.priority) + '</span>' : '<span style="color:var(--label-tertiary)">\u2014</span>') + '</span>';
    html += '</div>';

    // Executor
    if (t.executor) {
      html += '<div class="detail-prop">';
      html += '<span class="detail-prop-label">Executor</span>';
      html += '<span class="detail-prop-value"><span class="executor-badge ' + executorClass(t.executor) + '">' + executorLabel(t.executor) + '</span></span>';
      html += '</div>';
    }

    // Assignees
    if (t.assignees && t.assignees.length) {
      html += '<div class="detail-prop">';
      html += '<span class="detail-prop-label">Assignees</span>';
      html += '<span class="detail-prop-value">';
      t.assignees.forEach(function (a) {
        html += '<div class="detail-assignee"><div class="avatar">' + W.initials(a.name) + '</div><span class="detail-assignee-name">' + W.esc(a.name) + '</span></div>';
      });
      if (!t.acknowledgedAt) {
        html += '<span class="badge unack" style="margin-top:4px">Not yet acknowledged</span>';
      }
      html += '</span></div>';
    }

    // Due Date
    if (t.dueDate) {
      html += '<div class="detail-prop">';
      html += '<span class="detail-prop-label">Due Date</span>';
      html += '<span class="detail-prop-value">' + W.formatDate(t.dueDate) + '</span>';
      html += '</div>';
    }

    // Tags
    if (t.tags && t.tags.length) {
      html += '<div class="detail-prop">';
      html += '<span class="detail-prop-label">Tags</span>';
      html += '<span class="detail-prop-value"><div class="tags">' + t.tags.map(function (g) { return '<span class="tag">' + W.esc(g) + '</span>'; }).join('') + '</div></span>';
      html += '</div>';
    }

    // Project
    if (t.project) {
      html += '<div class="detail-prop">';
      html += '<span class="detail-prop-label">Project</span>';
      html += '<span class="detail-prop-value">' + W.esc(t.project) + '</span>';
      html += '</div>';
    }

    // Team
    if (t.team) {
      html += '<div class="detail-prop">';
      html += '<span class="detail-prop-label">Team</span>';
      html += '<span class="detail-prop-value">' + W.esc(t.team) + '</span>';
      html += '</div>';
    }

    // Requires Review
    if (t.requiresReview) {
      html += '<div class="detail-prop">';
      html += '<span class="detail-prop-label">Review</span>';
      html += '<span class="detail-prop-value"><span class="badge" style="background:rgba(191,90,242,0.15);color:var(--purple)">Review Required</span></span>';
      html += '</div>';
    }

    html += '</div>'; // end properties

    // Blocked By
    if (t.blockedBy && t.blockedBy.length) {
      html += '<div class="detail-section">';
      html += '<div class="detail-section-header">Blocked By</div>';
      html += '<div class="detail-section-content">';
      t.blockedBy.forEach(function (depId) {
        var dep = findTask(depId);
        var label = dep ? dep.title : depId.slice(0, 8) + '...';
        html += '<span class="detail-relation-link" onclick="Waggle.openDetail(\'' + depId + '\')">' + W.esc(label) + '</span>';
      });
      html += '</div></div>';
    }

    // Parent Task
    var parent = hierarchy.parentOf[t.id];
    if (parent) {
      html += '<div class="detail-section">';
      html += '<div class="detail-section-header">Parent Task</div>';
      html += '<div class="detail-section-content">';
      html += '<span class="detail-relation-link" onclick="Waggle.openDetail(\'' + parent.id + '\')">' + W.esc(parent.title) + '</span>';
      html += '</div></div>';
    }

    // Subtasks
    var stats = hierarchy.statsOf[t.id];
    if (stats) {
      var children = hierarchy.childrenOf[t.id] || [];
      html += '<div class="detail-section">';
      html += '<div class="detail-section-header">Subtasks (' + stats.done + '/' + stats.total + ' done)</div>';
      html += '<div class="detail-section-content">';
      html += '<div class="subtask-progress" style="margin-bottom:10px">';
      html += '<span class="subtask-progress-bar" style="width:100%;flex:1"><span class="subtask-progress-bar-fill" style="width:' + Math.round(stats.done / stats.total * 100) + '%"></span></span>';
      html += '</div>';
      children.forEach(function (c) {
        html += '<span class="detail-relation-link" onclick="Waggle.openDetail(\'' + c.id + '\')" style="margin-bottom:4px"><span class="badge ' + W.statusClass(c.status) + '" style="padding:1px 6px;font-size:10px;margin-right:4px">' + W.esc(c.status) + '</span>' + W.esc(c.title) + '</span>';
      });
      html += '</div></div>';
    }

    // Description
    if (t.description) {
      html += '<div class="detail-section">';
      html += '<div class="detail-section-header">Description</div>';
      html += '<div class="detail-section-content">' + W.esc(t.description) + '</div>';
      html += '</div>';
    }

    // Acceptance Criteria
    if (t.acceptanceCriteria) {
      html += '<div class="detail-section">';
      html += '<div class="detail-section-header">Acceptance Criteria</div>';
      html += '<div class="detail-section-content">' + W.esc(t.acceptanceCriteria) + '</div>';
      html += '</div>';
    }

    // Execution Plan
    if (t.executionPlan) {
      html += '<div class="detail-section">';
      html += '<div class="detail-section-header" onclick="toggleSection(this)"><span class="chevron">&#9660;</span> Execution Plan</div>';
      html += '<div class="detail-section-content">' + W.esc(t.executionPlan) + '</div>';
      html += '</div>';
    }

    // Context
    if (t.context) {
      html += '<div class="detail-section">';
      html += '<div class="detail-section-header" onclick="toggleSection(this)"><span class="chevron">&#9660;</span> Context</div>';
      html += '<div class="detail-section-content">' + W.esc(t.context) + '</div>';
      html += '</div>';
    }

    // Agent Output
    if (t.agentOutput) {
      html += '<div class="detail-section">';
      html += '<div class="detail-section-header" onclick="toggleSection(this)"><span class="chevron">&#9660;</span> Agent Output</div>';
      html += '<div class="detail-section-content mono">' + W.esc(t.agentOutput) + '</div>';
      html += '</div>';
    }

    // Error Message
    if (t.errorMessage) {
      html += '<div class="detail-section">';
      html += '<div class="detail-section-header">Error Message</div>';
      html += '<div class="detail-section-content error-text">' + W.esc(t.errorMessage) + '</div>';
      html += '</div>';
    }

    // Artifacts
    if (t.artifacts) {
      html += '<div class="detail-section">';
      html += '<div class="detail-section-header">Artifacts</div>';
      html += '<div class="detail-section-content">' + W.esc(t.artifacts) + '</div>';
      html += '</div>';
    }

    // Metadata footer
    var metaItems = [];
    if (t.dispatchedAt) metaItems.push({ label: 'Dispatched', value: new Date(t.dispatchedAt).toLocaleString() });
    if (t.acknowledgedAt) metaItems.push({ label: 'Acknowledged', value: new Date(t.acknowledgedAt).toLocaleString() });
    if (t.sessionReference) metaItems.push({ label: 'Session', value: t.sessionReference });
    if (t.workingDirectory) metaItems.push({ label: 'Working Dir', value: t.workingDirectory });
    if (t.repository) metaItems.push({ label: 'Repository', value: t.repository });

    if (metaItems.length) {
      html += '<div class="detail-metadata">';
      metaItems.forEach(function (m) {
        html += '<div class="detail-meta-item">';
        html += '<span class="detail-prop-label">' + m.label + '</span>';
        html += '<span class="detail-prop-value">' + W.esc(m.value) + '</span>';
        html += '</div>';
      });
      html += '</div>';
    }

    html += '</div>'; // end body

    panel.innerHTML = html;
    panel.classList.add('open');
    overlay.classList.add('open');
  }

  function closeDetail() {
    panel.classList.remove('open');
    overlay.classList.remove('open');
  }

  // Collapsible sections
  window.toggleSection = function (header) {
    header.classList.toggle('collapsed');
    var content = header.nextElementSibling;
    if (content) content.classList.toggle('collapsed');
  };

  // Expose on Waggle
  W.openDetail = openDetail;
  W.closeDetail = closeDetail;
})();
