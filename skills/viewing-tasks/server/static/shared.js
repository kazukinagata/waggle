/* Waggle — Shared Utilities & Data Layer */

(function () {
  'use strict';

  var today = new Date().toISOString().split('T')[0];

  // ── Utilities ──

  function esc(s) {
    return String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function initials(name) {
    return name.split(' ').map(function (n) { return n[0]; }).join('').slice(0, 2).toUpperCase();
  }

  function statusClass(s) {
    return { Backlog: 's-backlog', Ready: 's-ready', 'In Progress': 's-progress', 'In Review': 's-review', Done: 's-done', Blocked: 's-blocked', Cancelled: 's-cancelled' }[s] || 's-backlog';
  }

  function priorityClass(p) {
    return { Urgent: 'p-urgent', High: 'p-high', Medium: 'p-medium', Low: 'p-low' }[p] || '';
  }

  function formatDate(d) {
    if (!d) return '';
    var overdue = d < today;
    return '<span class="due-date' + (overdue ? ' overdue' : '') + '">' + d + (overdue ? ' \u26A0' : '') + '</span>';
  }

  // ── Hierarchy ──

  function buildHierarchy(tasks) {
    var byId = {};
    tasks.forEach(function (t) { byId[t.id] = t; });
    var childrenOf = {};
    var parentOf = {};
    tasks.forEach(function (t) {
      if (t.parentTaskId && byId[t.parentTaskId]) {
        if (!childrenOf[t.parentTaskId]) childrenOf[t.parentTaskId] = [];
        childrenOf[t.parentTaskId].push(t);
        parentOf[t.id] = byId[t.parentTaskId];
      }
    });
    var statsOf = {};
    Object.keys(childrenOf).forEach(function (pid) {
      var children = childrenOf[pid];
      statsOf[pid] = { total: children.length, done: children.filter(function (c) { return c.status === 'Done'; }).length };
    });
    return { childrenOf: childrenOf, parentOf: parentOf, statsOf: statsOf };
  }

  // ── Toast ──

  function showToast(msg) {
    var t = document.getElementById('toast');
    if (!t) return;
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(t._timer);
    t._timer = setTimeout(function () { t.classList.remove('show'); }, 2000);
  }

  function copyId(id) {
    navigator.clipboard.writeText(id).catch(function () {});
    showToast('ID copied: ' + id.slice(0, 8) + '...');
  }

  // ── Filter Engine ──

  var filters = {
    search: '',
    statuses: [],
    priorities: [],
    executors: [],
    assigneeIds: [],
    tags: [],
    dueDate: '',
    blockedOnly: false
  };

  function getFiltered() {
    var search = filters.search.toLowerCase();
    return W.allTasks.filter(function (t) {
      if (search && !t.title.toLowerCase().includes(search) && !(t.description || '').toLowerCase().includes(search)) return false;
      if (filters.statuses.length && filters.statuses.indexOf(t.status) === -1) return false;
      if (filters.priorities.length && filters.priorities.indexOf(t.priority) === -1) return false;
      if (filters.executors.length && filters.executors.indexOf(t.executor) === -1) return false;
      if (filters.assigneeIds.length) {
        var taskAssigneeIds = (t.assignee || []).map(function (a) { return a.id; });
        if (!filters.assigneeIds.some(function (id) { return taskAssigneeIds.indexOf(id) !== -1; })) return false;
      }
      if (filters.tags.length) {
        var taskTags = t.tags || [];
        if (!filters.tags.some(function (tag) { return taskTags.indexOf(tag) !== -1; })) return false;
      }
      if (filters.dueDate) {
        switch (filters.dueDate) {
          case 'has': if (!t.dueDate) return false; break;
          case 'none': if (t.dueDate) return false; break;
          case 'overdue': if (!t.dueDate || t.dueDate >= today) return false; break;
          case 'this-week': {
            if (!t.dueDate) return false;
            var d = new Date();
            var weekEnd = new Date(d);
            weekEnd.setDate(d.getDate() + (7 - d.getDay()));
            var weekEndStr = weekEnd.toISOString().split('T')[0];
            if (t.dueDate < today || t.dueDate > weekEndStr) return false;
            break;
          }
          case 'this-month': {
            if (!t.dueDate) return false;
            var monthEnd = new Date(new Date().getFullYear(), new Date().getMonth() + 1, 0).toISOString().split('T')[0];
            if (t.dueDate < today || t.dueDate > monthEnd) return false;
            break;
          }
        }
      }
      if (filters.blockedOnly && t.status !== 'Blocked') return false;
      return true;
    });
  }

  // ── URL State ──

  function saveFiltersToURL(extraParams) {
    var params = new URLSearchParams();
    if (filters.search) params.set('search', filters.search);
    if (filters.statuses.length) params.set('status', filters.statuses.join(','));
    if (filters.priorities.length) params.set('priority', filters.priorities.join(','));
    if (filters.executors.length) params.set('executor', filters.executors.join(','));
    if (filters.assigneeIds.length) params.set('assignee', filters.assigneeIds.join(','));
    if (filters.tags.length) params.set('tag', filters.tags.join(','));
    if (filters.dueDate) params.set('due', filters.dueDate);
    if (filters.blockedOnly) params.set('blocked', '1');
    if (extraParams) {
      Object.keys(extraParams).forEach(function (k) {
        if (extraParams[k]) params.set(k, extraParams[k]);
      });
    }
    var hash = params.toString();
    history.replaceState(null, '', hash ? '#' + hash : location.pathname + location.search);
  }

  function loadFiltersFromURL() {
    var hash = location.hash.slice(1);
    if (!hash) return {};
    var params = new URLSearchParams(hash);
    if (params.get('search')) filters.search = params.get('search');
    if (params.get('status')) filters.statuses = params.get('status').split(',');
    if (params.get('priority')) filters.priorities = params.get('priority').split(',');
    if (params.get('executor')) filters.executors = params.get('executor').split(',');
    if (params.get('assignee')) filters.assigneeIds = params.get('assignee').split(',');
    if (params.get('tag')) filters.tags = params.get('tag').split(',');
    if (params.get('due')) filters.dueDate = params.get('due');
    if (params.get('blocked')) filters.blockedOnly = true;
    // Return extra params for view-specific state
    var extra = {};
    params.forEach(function (v, k) {
      if (['search', 'status', 'priority', 'executor', 'assignee', 'tag', 'due', 'blocked'].indexOf(k) === -1) {
        extra[k] = v;
      }
    });
    return extra;
  }

  // ── Data Layer ──

  var allTasks = [];
  var hierarchy = {};

  function updateData(data) {
    allTasks = data.tasks || [];
    hierarchy = buildHierarchy(allTasks);
    W.allTasks = allTasks;
    W.hierarchy = hierarchy;
    var countEl = document.getElementById('task-count');
    var updatedEl = document.getElementById('updated-at');
    if (countEl) countEl.textContent = allTasks.length + ' tasks';
    if (updatedEl && data.updatedAt) updatedEl.textContent = 'Updated: ' + new Date(data.updatedAt).toLocaleTimeString();
    if (W.onFilterBarUpdate) W.onFilterBarUpdate();
    if (W.onDataUpdate) W.onDataUpdate();
  }

  function fetchTasks() {
    return fetch('/api/tasks')
      .then(function (res) {
        if (!res.ok) throw new Error(res.statusText);
        return res.json();
      })
      .then(function (data) { updateData(data); })
      .catch(function (e) {
        var s = document.getElementById('sse-status');
        if (s) s.textContent = 'Error: ' + e.message;
      });
  }

  function connectSSE() {
    var dot = document.getElementById('sse-dot');
    var status = document.getElementById('sse-status');
    var es = new EventSource('/api/events');
    es.addEventListener('connected', function () {
      if (dot) dot.classList.remove('disconnected');
      if (status) status.textContent = 'Live';
    });
    es.addEventListener('refresh', function (e) {
      try {
        updateData(JSON.parse(e.data));
      } catch (err) { fetchTasks(); }
    });
    es.onerror = function () {
      if (dot) dot.classList.add('disconnected');
      if (status) status.textContent = 'Reconnecting...';
      es.close();
      setTimeout(connectSSE, 3000);
    };
  }

  function initData() {
    if (window.__STATIC_DATA__) {
      updateData(window.__STATIC_DATA__);
      var dot = document.getElementById('sse-dot');
      var status = document.getElementById('sse-status');
      var updatedEl = document.getElementById('updated-at');
      if (dot) dot.style.display = 'none';
      if (status) status.textContent = 'Static';
      if (updatedEl && window.__STATIC_DATA__.updatedAt) {
        updatedEl.textContent = 'Generated: ' + new Date(window.__STATIC_DATA__.updatedAt).toLocaleTimeString();
      }
    } else {
      fetchTasks();
      connectSSE();
    }
  }

  // ── Keyboard Navigation ──

  var keyboardState = {
    selectedIndex: -1,
    active: false,
    getNavigableTasks: null,
    getTaskElement: null
  };

  function clearKeyboardSelection() {
    document.querySelectorAll('.keyboard-selected').forEach(function (el) {
      el.classList.remove('keyboard-selected');
    });
    keyboardState.selectedIndex = -1;
  }

  function applyKeyboardSelection() {
    document.querySelectorAll('.keyboard-selected').forEach(function (el) {
      el.classList.remove('keyboard-selected');
    });
    if (!keyboardState.getNavigableTasks || !keyboardState.getTaskElement) return;
    var tasks = keyboardState.getNavigableTasks();
    if (keyboardState.selectedIndex < 0 || keyboardState.selectedIndex >= tasks.length) return;
    var el = keyboardState.getTaskElement(tasks[keyboardState.selectedIndex]);
    if (el) {
      el.classList.add('keyboard-selected');
      el.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
  }

  function initKeyboard(config) {
    keyboardState.getNavigableTasks = config.getNavigableTasks;
    keyboardState.getTaskElement = config.getTaskElement;

    document.addEventListener('mousemove', function () {
      if (keyboardState.active) {
        keyboardState.active = false;
        clearKeyboardSelection();
      }
    }, { passive: true });

    document.addEventListener('keydown', function (e) {
      // Don't handle when typing in inputs
      if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.tagName === 'SELECT') {
        if (e.key === 'Escape') {
          e.target.blur();
          e.preventDefault();
        }
        return;
      }

      var tasks = keyboardState.getNavigableTasks ? keyboardState.getNavigableTasks() : [];

      switch (e.key) {
        case '/':
          e.preventDefault();
          var searchEl = document.querySelector('.search-input') || document.getElementById('filter-search');
          if (searchEl) searchEl.focus();
          break;

        case 'Escape':
          // Cascade: detail panel -> filter dropdown -> keyboard selection
          if (W.closeDetail && document.querySelector('.detail-panel.open')) {
            W.closeDetail();
          } else {
            clearKeyboardSelection();
          }
          e.preventDefault();
          break;

        case 'j':
        case 'ArrowDown':
          if (tasks.length === 0) break;
          e.preventDefault();
          keyboardState.active = true;
          keyboardState.selectedIndex = Math.min(keyboardState.selectedIndex + 1, tasks.length - 1);
          applyKeyboardSelection();
          break;

        case 'k':
        case 'ArrowUp':
          if (tasks.length === 0) break;
          e.preventDefault();
          keyboardState.active = true;
          keyboardState.selectedIndex = Math.max(keyboardState.selectedIndex - 1, 0);
          applyKeyboardSelection();
          break;

        case 'Enter':
          if (keyboardState.selectedIndex >= 0 && keyboardState.selectedIndex < tasks.length) {
            e.preventDefault();
            if (W.openDetail) W.openDetail(tasks[keyboardState.selectedIndex]);
          }
          break;

        case 'c':
          if (keyboardState.selectedIndex >= 0 && keyboardState.selectedIndex < tasks.length) {
            copyId(tasks[keyboardState.selectedIndex]);
          }
          break;
      }
    });
  }

  // ── Expose Namespace ──

  var W = window.Waggle = {
    // Utilities
    esc: esc,
    initials: initials,
    statusClass: statusClass,
    priorityClass: priorityClass,
    formatDate: formatDate,
    buildHierarchy: buildHierarchy,
    today: today,

    // Toast / clipboard
    showToast: showToast,
    copyId: copyId,

    // Data layer
    allTasks: allTasks,
    hierarchy: hierarchy,
    onDataUpdate: null,
    onFilterBarUpdate: null,
    fetchTasks: fetchTasks,
    connectSSE: connectSSE,
    initData: initData,

    // Filter engine
    filters: filters,
    getFiltered: getFiltered,

    // URL state
    saveFiltersToURL: saveFiltersToURL,
    loadFiltersFromURL: loadFiltersFromURL,

    // Keyboard
    initKeyboard: initKeyboard,
    clearKeyboardSelection: clearKeyboardSelection,

    // Detail panel (set by detail-panel.js)
    openDetail: null,
    closeDetail: null
  };
})();
