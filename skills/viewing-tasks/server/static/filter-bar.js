/* Waggle — Advanced Filter Bar */

(function () {
  'use strict';

  var W = window.Waggle;
  if (!W) return;

  var container = document.getElementById('filter-bar');
  if (!container) return;

  var STATIC_FILTERS = [
    { key: 'statuses', label: 'Status', options: ['Backlog', 'Ready', 'In Progress', 'In Review', 'Blocked', 'Done', 'Cancelled'] },
    { key: 'priorities', label: 'Priority', options: ['Urgent', 'High', 'Medium', 'Low'] },
    { key: 'executors', label: 'Executor', options: ['cli', 'claude-desktop', 'cowork', 'human'] },
    { key: 'assigneeIds', label: 'Assignee', options: [], dynamic: true },
    { key: 'tags', label: 'Tags', options: [], dynamic: true }
  ];

  var DUE_OPTIONS = [
    { value: '', label: 'Any' },
    { value: 'has', label: 'Has due date' },
    { value: 'none', label: 'No due date' },
    { value: 'overdue', label: 'Overdue' },
    { value: 'this-week', label: 'Due this week' },
    { value: 'this-month', label: 'Due this month' }
  ];

  var START_OPTIONS = [
    { value: '', label: 'Any' },
    { value: 'has', label: 'Has start date' },
    { value: 'none', label: 'No start date' }
  ];

  var openDropdown = null;

  function collectDynamicOptions() {
    var assigneeMap = {};
    var tagSet = {};
    W.allTasks.forEach(function (t) {
      (t.assignee || []).forEach(function (a) { assigneeMap[a.id] = a.name; });
      (t.tags || []).forEach(function (g) { tagSet[g] = true; });
    });

    STATIC_FILTERS.forEach(function (f) {
      if (f.key === 'assigneeIds') {
        f.options = Object.keys(assigneeMap).map(function (id) { return { value: id, label: assigneeMap[id] }; });
      } else if (f.key === 'tags') {
        f.options = Object.keys(tagSet).sort().map(function (g) { return { value: g, label: g }; });
      }
    });
  }

  function getFilterValues(key) {
    return W.filters[key] || [];
  }

  function onFilterChange() {
    W.saveFiltersToURL();
    renderActivePills();
    updateResultsCount();
    if (W.onDataUpdate) W.onDataUpdate();
  }

  function closeAllDropdowns() {
    container.querySelectorAll('.filter-dropdown.open').forEach(function (dd) {
      dd.classList.remove('open');
    });
    openDropdown = null;
  }

  // Close dropdowns when clicking outside
  document.addEventListener('click', function (e) {
    if (!e.target.closest('.filter-pill') && !e.target.closest('.filter-dropdown')) {
      closeAllDropdowns();
    }
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && openDropdown) {
      closeAllDropdowns();
      e.stopPropagation();
    }
  });

  function renderBar() {
    collectDynamicOptions();

    var html = '';

    // Search
    html += '<div class="filter-bar-search">';
    html += '<input type="text" id="filter-search" class="search-input" placeholder="Search tasks..." value="' + W.esc(W.filters.search) + '">';
    html += '</div>';

    // Multi-select filter pills
    STATIC_FILTERS.forEach(function (f, idx) {
      var values = getFilterValues(f.key);
      var isActive = values.length > 0;
      html += '<div class="filter-pill' + (isActive ? ' active' : '') + '" data-filter-idx="' + idx + '" onclick="window._filterBarToggle(' + idx + ', event)">';
      html += f.label;
      if (isActive) {
        html += ' <span class="count-badge">' + values.length + '</span>';
      }
      html += ' <span class="chevron-down">&#9662;</span>';

      // Dropdown
      html += '<div class="filter-dropdown" id="filter-dd-' + idx + '">';
      if (f.dynamic && f.options.length > 5) {
        html += '<div class="filter-dropdown-search"><input type="text" placeholder="Search..." oninput="window._filterBarSearchDropdown(' + idx + ', this.value)"></div>';
      }
      html += '<div class="filter-dropdown-list" id="filter-dd-list-' + idx + '">';
      html += renderDropdownItems(f, values);
      html += '</div>';
      if (isActive) {
        html += '<div class="filter-dropdown-footer"><button class="filter-dropdown-clear" onclick="window._filterBarClear(' + idx + ', event)">Clear</button></div>';
      }
      html += '</div>';

      html += '</div>';
    });

    // Start date filter
    var startActive = !!W.filters.startDate;
    html += '<div class="filter-pill' + (startActive ? ' active' : '') + '" data-filter-key="startDate" onclick="window._filterBarToggleStart(event)">';
    html += 'Start Date';
    if (startActive) {
      html += ' <span class="count-badge">1</span>';
    }
    html += ' <span class="chevron-down">&#9662;</span>';

    html += '<div class="filter-dropdown" id="filter-dd-start">';
    html += '<div class="filter-dropdown-list">';
    START_OPTIONS.forEach(function (o) {
      var selected = W.filters.startDate === o.value;
      html += '<div class="filter-dropdown-item" onclick="window._filterBarSetStart(\'' + o.value + '\', event)" style="' + (selected ? 'color:var(--blue);font-weight:600' : '') + '">';
      html += (selected ? '&#10003; ' : '&nbsp;&nbsp;&nbsp; ') + W.esc(o.label);
      html += '</div>';
    });
    html += '</div></div>';
    html += '</div>';

    // Due date filter
    var dueActive = !!W.filters.dueDate;
    html += '<div class="filter-pill' + (dueActive ? ' active' : '') + '" data-filter-key="dueDate" onclick="window._filterBarToggleDue(event)">';
    html += 'Due Date';
    if (dueActive) {
      html += ' <span class="count-badge">1</span>';
    }
    html += ' <span class="chevron-down">&#9662;</span>';

    html += '<div class="filter-dropdown" id="filter-dd-due">';
    html += '<div class="filter-dropdown-list">';
    DUE_OPTIONS.forEach(function (o) {
      var selected = W.filters.dueDate === o.value;
      html += '<div class="filter-dropdown-item" onclick="window._filterBarSetDue(\'' + o.value + '\', event)" style="' + (selected ? 'color:var(--blue);font-weight:600' : '') + '">';
      html += (selected ? '&#10003; ' : '&nbsp;&nbsp;&nbsp; ') + W.esc(o.label);
      html += '</div>';
    });
    html += '</div></div>';
    html += '</div>';

    // Results count
    html += '<span class="filter-results-count" id="filter-results-count"></span>';

    container.className = 'filter-bar';
    container.innerHTML = html;

    // Search listener
    var searchInput = document.getElementById('filter-search');
    if (searchInput) {
      searchInput.addEventListener('input', function () {
        W.filters.search = this.value;
        onFilterChange();
      });
    }

    renderActivePills();
    updateResultsCount();
  }

  function renderDropdownItems(f, values) {
    var options = f.options;
    var html = '';
    options.forEach(function (opt) {
      var val = typeof opt === 'object' ? opt.value : opt;
      var label = typeof opt === 'object' ? opt.label : opt;
      var checked = values.indexOf(val) !== -1;
      html += '<div class="filter-dropdown-item" data-value="' + W.esc(val) + '" onclick="window._filterBarToggleItem(\'' + f.key + '\', \'' + W.esc(val) + '\', event)">';
      html += '<input type="checkbox"' + (checked ? ' checked' : '') + ' tabindex="-1">';
      html += '<span>' + W.esc(label) + '</span>';
      html += '</div>';
    });
    return html;
  }

  function renderActivePills() {
    var existing = document.getElementById('filter-active-pills');
    if (existing) existing.remove();

    var pills = [];

    STATIC_FILTERS.forEach(function (f) {
      var values = getFilterValues(f.key);
      if (!values.length) return;
      values.forEach(function (v) {
        var label = v;
        if (f.dynamic) {
          var opt = f.options.find(function (o) { return (typeof o === 'object' ? o.value : o) === v; });
          if (opt && typeof opt === 'object') label = opt.label;
        }
        pills.push({ key: f.key, value: v, display: f.label + ': ' + label });
      });
    });

    if (W.filters.startDate) {
      var startLabel = START_OPTIONS.find(function (o) { return o.value === W.filters.startDate; });
      pills.push({ key: 'startDate', value: W.filters.startDate, display: 'Start: ' + (startLabel ? startLabel.label : W.filters.startDate) });
    }

    if (W.filters.dueDate) {
      var dueLabel = DUE_OPTIONS.find(function (o) { return o.value === W.filters.dueDate; });
      pills.push({ key: 'dueDate', value: W.filters.dueDate, display: 'Due: ' + (dueLabel ? dueLabel.label : W.filters.dueDate) });
    }

    if (pills.length === 0) return;

    var div = document.createElement('div');
    div.className = 'filter-active-pills';
    div.id = 'filter-active-pills';

    var html = '';
    pills.forEach(function (p) {
      html += '<span class="filter-active-pill">' + W.esc(p.display) + ' <span class="remove" onclick="window._filterBarRemovePill(\'' + p.key + '\',\'' + W.esc(p.value) + '\')">&times;</span></span>';
    });
    html += '<button class="filter-clear-all" onclick="window._filterBarClearAll()">Clear all</button>';

    div.innerHTML = html;
    container.after(div);
  }

  function updateResultsCount() {
    var el = document.getElementById('filter-results-count');
    if (!el) return;
    var filtered = W.getFiltered().length;
    var total = W.allTasks.length;
    if (filtered === total) {
      el.textContent = total + ' tasks';
    } else {
      el.textContent = filtered + ' of ' + total + ' tasks';
    }
  }

  // Global handlers
  window._filterBarToggle = function (idx, event) {
    event.stopPropagation();
    var dd = document.getElementById('filter-dd-' + idx);
    if (!dd) return;
    var wasOpen = dd.classList.contains('open');
    closeAllDropdowns();
    if (!wasOpen) {
      dd.classList.add('open');
      openDropdown = dd;
      var searchInput = dd.querySelector('.filter-dropdown-search input');
      if (searchInput) searchInput.focus();
    }
  };

  window._filterBarToggleDue = function (event) {
    event.stopPropagation();
    var dd = document.getElementById('filter-dd-due');
    if (!dd) return;
    var wasOpen = dd.classList.contains('open');
    closeAllDropdowns();
    if (!wasOpen) {
      dd.classList.add('open');
      openDropdown = dd;
    }
  };

  window._filterBarToggleStart = function (event) {
    event.stopPropagation();
    var dd = document.getElementById('filter-dd-start');
    if (!dd) return;
    var wasOpen = dd.classList.contains('open');
    closeAllDropdowns();
    if (!wasOpen) {
      dd.classList.add('open');
      openDropdown = dd;
    }
  };

  window._filterBarToggleItem = function (key, value, event) {
    event.stopPropagation();
    var values = getFilterValues(key).slice();
    var idx = values.indexOf(value);
    if (idx === -1) {
      values.push(value);
    } else {
      values.splice(idx, 1);
    }
    W.filters[key] = values;
    renderBar();
    onFilterChange();
  };

  window._filterBarSetDue = function (value, event) {
    event.stopPropagation();
    W.filters.dueDate = value;
    closeAllDropdowns();
    renderBar();
    onFilterChange();
  };

  window._filterBarSetStart = function (value, event) {
    event.stopPropagation();
    W.filters.startDate = value;
    closeAllDropdowns();
    renderBar();
    onFilterChange();
  };

  window._filterBarClear = function (idx, event) {
    event.stopPropagation();
    var f = STATIC_FILTERS[idx];
    W.filters[f.key] = [];
    closeAllDropdowns();
    renderBar();
    onFilterChange();
  };

  window._filterBarRemovePill = function (key, value) {
    if (key === 'dueDate') {
      W.filters.dueDate = '';
    } else if (key === 'startDate') {
      W.filters.startDate = '';
    } else {
      W.filters[key] = getFilterValues(key).filter(function (v) { return v !== value; });
    }
    renderBar();
    onFilterChange();
  };

  window._filterBarClearAll = function () {
    W.filters.search = '';
    W.filters.statuses = [];
    W.filters.priorities = [];
    W.filters.executors = [];
    W.filters.assigneeIds = [];
    W.filters.tags = [];
    W.filters.startDate = '';
    W.filters.dueDate = '';
    W.filters.blockedOnly = false;
    renderBar();
    onFilterChange();
  };

  window._filterBarSearchDropdown = function (idx, query) {
    var list = document.getElementById('filter-dd-list-' + idx);
    if (!list) return;
    var q = query.toLowerCase();
    list.querySelectorAll('.filter-dropdown-item').forEach(function (item) {
      var text = item.querySelector('span').textContent.toLowerCase();
      item.style.display = text.includes(q) ? '' : 'none';
    });
  };

  // Init and re-render on data updates
  W.onFilterBarUpdate = function () {
    collectDynamicOptions();
    renderBar();
  };

  renderBar();
})();
