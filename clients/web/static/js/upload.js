// Browser upload module (DESIGN.md sections 7 and 13). Talks to the same
// /v1 JSON endpoints as native clients, authenticated by the HttpOnly session
// cookie plus the CSRF header; the browser never holds bearer tokens.
// Upload state lives outside htmx-swapped fragments.
(function () {
  "use strict";

  var STORAGE_KEY = "libarrie.pendingUploads";

  function csrfToken() {
    try {
      return JSON.parse(document.body.getAttribute("hx-headers") || "{}")["X-CSRF-Token"] || "";
    } catch (e) { return ""; }
  }

  function api(method, path, body, extraHeaders) {
    return fetch(path, {
      method: method,
      credentials: "same-origin",
      headers: Object.assign(
        { "Accept": "application/json", "X-CSRF-Token": csrfToken() },
        body ? { "Content-Type": "application/json" } : {},
        extraHeaders || {}
      ),
      body: body ? JSON.stringify(body) : undefined
    }).then(function (response) {
      if (response.status === 401) {
        window.location.assign("/auth/login?return_to=" + encodeURIComponent(window.location.pathname));
        throw new Error("signed out");
      }
      return response.json().catch(function () { return {}; }).then(function (data) {
        return { status: response.status, data: data };
      });
    });
  }

  function hex(buffer) {
    return Array.prototype.map.call(new Uint8Array(buffer), function (b) {
      return ("0" + b.toString(16)).slice(-2);
    }).join("");
  }

  function loadPending() {
    try { return JSON.parse(window.localStorage.getItem(STORAGE_KEY) || "[]"); }
    catch (e) { return []; }
  }

  function savePending(list) {
    try { window.localStorage.setItem(STORAGE_KEY, JSON.stringify(list)); } catch (e) { /* storage full or disabled */ }
  }

  function remember(entry) {
    var list = loadPending().filter(function (e) { return e.operation_id !== entry.operation_id; });
    list.push(entry);
    savePending(list);
  }

  function forget(operationId) {
    savePending(loadPending().filter(function (e) { return e.operation_id !== operationId; }));
    deleteBytes(operationId);
  }

  // Selected photos survive a page refresh: until the server accepts an
  // upload, its exact bytes and request are kept in this origin's
  // IndexedDB, so recovery replays the same operation (the server
  // deduplicates it) instead of asking for the file again. Nothing is
  // promised after the browser's storage is cleared or the quota is
  // exceeded; then the user is asked to choose the photo again.
  var DB_NAME = "libarrie-uploads";

  function database() {
    return new Promise(function (resolve, reject) {
      if (!window.indexedDB) return reject(new Error("no IndexedDB"));
      var request = window.indexedDB.open(DB_NAME, 1);
      request.onupgradeneeded = function () {
        request.result.createObjectStore("files", { keyPath: "operation_id" });
      };
      request.onsuccess = function () { resolve(request.result); };
      request.onerror = function () { reject(request.error); };
    });
  }

  function withStore(mode, action) {
    return database().then(function (db) {
      return new Promise(function (resolve, reject) {
        var tx = db.transaction("files", mode);
        var result = action(tx.objectStore("files"));
        tx.oncomplete = function () { db.close(); resolve(result && result.result); };
        tx.onerror = tx.onabort = function () { db.close(); reject(tx.error); };
      });
    });
  }

  function saveBytes(record) {
    return withStore("readwrite", function (store) { return store.put(record); }).catch(function () {});
  }

  function loadBytes(operationId) {
    return withStore("readonly", function (store) { return store.get(operationId); }).catch(function () { return null; });
  }

  function deleteBytes(operationId) {
    withStore("readwrite", function (store) { return store.delete(operationId); }).catch(function () {});
  }

  // HEIC/HEIF: convert only with decoders already in this browser.
  function normalize(file) {
    var type = (file.type || "").toLowerCase();
    var isHeic = /hei[cf]/.test(type) || /\.hei[cf]$/i.test(file.name);
    if (type === "image/jpeg" || type === "image/png") return Promise.resolve(file);
    if (!isHeic) return Promise.reject(new Error("Only JPEG, PNG and (where your browser supports it) HEIC photos can be uploaded."));
    if (!window.createImageBitmap) return Promise.reject(heicHelp());
    return window.createImageBitmap(file).then(function (bitmap) {
      var canvas = document.createElement("canvas");
      canvas.width = bitmap.width;
      canvas.height = bitmap.height;
      canvas.getContext("2d").drawImage(bitmap, 0, 0);
      if (bitmap.close) bitmap.close();
      return new Promise(function (resolve, reject) {
        canvas.toBlob(function (blob) {
          if (!blob) return reject(heicHelp());
          resolve(new File([blob], file.name.replace(/\.hei[cf]$/i, ".jpg"), { type: "image/jpeg" }));
        }, "image/jpeg", 0.92);
      });
    }, function () { throw heicHelp(); });
  }

  function heicHelp() {
    return new Error("This browser cannot read HEIC photos. Export the photo as JPEG (for example from the share sheet), set the iPhone camera format to Most Compatible, or upload from the Libarrie app.");
  }

  function putWithProgress(upload, blob, onProgress) {
    return new Promise(function (resolve, reject) {
      var xhr = new XMLHttpRequest();
      xhr.open("PUT", upload.url);
      Object.keys(upload.headers || {}).forEach(function (name) {
        xhr.setRequestHeader(name, upload.headers[name]);
      });
      xhr.upload.onprogress = function (event) {
        if (event.lengthComputable) onProgress(event.loaded / event.total);
      };
      xhr.onload = function () {
        if (xhr.status >= 200 && xhr.status < 300) resolve();
        else reject(new Error("The storage service rejected the upload (" + xhr.status + ")."));
      };
      xhr.onerror = function () { reject(new Error("The upload was interrupted. Check your connection and retry.")); };
      xhr.send(blob);
    });
  }

  function row(queue, name) {
    var li = document.createElement("li");
    var label = document.createElement("span");
    label.className = "name";
    label.textContent = name;
    var progress = document.createElement("progress");
    progress.max = 1;
    progress.value = 0;
    var state = document.createElement("span");
    state.className = "badge progress";
    state.textContent = "Preparing";
    li.appendChild(label);
    li.appendChild(progress);
    li.appendChild(state);
    queue.appendChild(li);
    return {
      li: li,
      progress: progress,
      set: function (text, kind) {
        state.textContent = text;
        state.className = "badge " + (kind || "progress");
      }
    };
  }

  // `target` is either { notebook_id, page_number } for a new page or
  // { page_id } for a replacement scan (always processed immediately).
  function uploadOne(context, file, target, view) {
    var operationId = (window.crypto.randomUUID && window.crypto.randomUUID()) || fallbackUuid();
    var pageNumber = target.page_number;
    return normalize(file).then(function (blob) {
      return blob.arrayBuffer().then(function (buffer) {
        return window.crypto.subtle.digest("SHA-256", buffer).then(function (digest) {
          var body = Object.assign({
            operation_id: operationId,
            bytes: blob.size,
            content_type: blob.type,
            checksum_sha256: hex(digest),
            processing_mode: context.deferred ? "deferred" : "immediate",
            client_label: "web"
          }, target);
          if (context.integrity === "md5") body.checksum_md5 = window.LibarrieMd5(new Uint8Array(buffer));
          // Replacements are conditional on the page content they replace.
          var headers = context.contentVersion ? { "If-Match": '"c' + context.contentVersion + '"' } : null;
          var entry = Object.assign({ operation_id: operationId, name: file.name, account_id: context.accountId }, target);
          remember(entry);
          return saveBytes({ operation_id: operationId, body: body, headers: headers, blob: blob }).then(function () {
            return send(context, operationId, body, headers, blob, view, pageNumber);
          });
        });
      });
    });
  }

  // Reserve (or replay the reservation of) one operation, upload its bytes
  // and complete it.
  function send(context, operationId, body, headers, blob, view, pageNumber) {
    view.set("Reserving");
    return api("POST", "/v1/upload-sessions", body, headers).then(function (created) {
      if ((created.status === 409 || created.status === 412) && created.data.error) {
        forget(operationId);
        var code = created.data.error.code;
        if (code === "page_number_conflict") throw new Error("Page " + pageNumber + " is already used in this notebook. Choose another starting page.");
        if (code === "processing_conflict") throw new Error("This page is being processed. Try again when it finishes.");
        if (code === "version_conflict") throw new Error("This page changed since you opened it. Reload and try again.");
        if (code === "processing_limit_reached") {
          var err = new Error("Your processing allowance is used up.");
          err.offerDeferred = true;
          throw err;
        }
        throw new Error(created.data.error.message);
      }
      if (created.status >= 400) {
        forget(operationId);
        throw new Error((created.data.error && created.data.error.message) || "The upload could not start.");
      }
      // A replay of an operation that already got past the upload.
      if (!created.data.upload) {
        forget(operationId);
        view.progress.value = 1;
        view.set("Uploaded", "ok");
        return;
      }
      view.set("Uploading");
      return putWithProgress(created.data.upload, blob, function (fraction) {
        view.progress.value = fraction;
      }).then(function () {
        view.set("Confirming");
        return api("POST", "/v1/upload-sessions/" + created.data.upload_session_id + "/complete");
      }).then(function (done) {
        if (done.status >= 400) throw new Error((done.data.error && done.data.error.message) || "The upload could not be confirmed.");
        forget(operationId);
        view.progress.value = 1;
        view.set(body.processing_mode === "deferred" ? "Uploaded; processing later" : "Uploaded; processing", "ok");
        if (context.onDone) context.onDone();
      });
    });
  }

  function fallbackUuid() {
    var b = window.crypto.getRandomValues(new Uint8Array(16));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var h = hex(b);
    return h.slice(0, 8) + "-" + h.slice(8, 12) + "-" + h.slice(12, 16) + "-" + h.slice(16, 20) + "-" + h.slice(20);
  }

  // After a refresh, finish uploads from this browser: with the kept bytes
  // the same operation is replayed; without them the user is told.
  // Entries from another account are discarded, never uploaded.
  function recover(context, queue, matches, describe) {
    loadPending().forEach(function (entry) {
      if (entry.account_id !== context.accountId) forget(entry.operation_id);
    });
    loadPending()
      .filter(matches)
      .forEach(function (entry) {
        var view = row(queue, describe(entry));
        loadBytes(entry.operation_id).then(function (stored) {
          api("GET", "/v1/operations/" + entry.operation_id).then(function (result) {
            var status = result.data && result.data.status;
            var finished = result.status === 200 && status !== "awaiting_upload";
            if (finished) {
              forget(entry.operation_id);
              var accepted = !!result.data.upload_accepted_at;
              view.progress.value = accepted ? 1 : 0;
              view.set(accepted ? "Uploaded" : "This upload expired; choose the photo again", accepted ? "ok" : "warning");
            } else if (stored && stored.blob) {
              // Not created yet (404) or still waiting for bytes: replay.
              send(context, entry.operation_id, stored.body, stored.headers, stored.blob, view, entry.page_number)
                .catch(function (error) { view.set(error.message, "danger"); });
            } else if (result.status === 404) {
              forget(entry.operation_id);
              view.set("Not started; choose the photo again", "warning");
            } else {
              view.set("Interrupted; choose the photo again to resume", "warning");
            }
          });
        });
      });
  }

  function init(root) {
    if (!root || root.dataset.ready) return;
    root.dataset.ready = "true";
    var context = {
      notebookId: root.dataset.notebookId,
      accountId: root.dataset.accountId,
      integrity: root.dataset.integrity || "sha256",
      deferred: false
    };
    var input = root.querySelector("#files");
    var start = root.querySelector("#start-page");
    var button = root.querySelector("#start-upload");
    var queue = root.querySelector("#upload-queue");
    recover(context, queue,
      function (e) { return e.notebook_id === context.notebookId && !e.page_id; },
      function (e) { return e.name + " (page " + e.page_number + ")"; });
    button.addEventListener("click", function () {
      var files = Array.prototype.slice.call(input.files || []);
      if (files.length === 0) { input.focus(); return; }
      var first = parseInt(start.value, 10) || 1;
      button.disabled = true;
      var chain = Promise.resolve();
      files.forEach(function (file, index) {
        var view = row(queue, file.name + " (page " + (first + index) + ")");
        chain = chain.then(function () {
          var target = { notebook_id: context.notebookId, page_number: first + index };
          return uploadOne(context, file, target, view).catch(function (error) {
            if (error.offerDeferred && !context.asked) {
              context.asked = true;
              // Ask once per batch (section 13).
              context.deferred = window.confirm("Your processing allowance is used up. Upload now and make the pages searchable later?");
              if (context.deferred) return uploadOne(context, file, target, view);
            }
            view.set(error.message, "danger");
          });
        });
      });
      chain.then(function () {
        button.disabled = false;
        start.value = String(first + files.length);
        input.value = "";
      });
    });
  }

  // Replacement scan on the page detail screen.
  function initReplace(root) {
    if (!root || root.dataset.ready) return;
    root.dataset.ready = "true";
    var pageId = root.dataset.pageId;
    var input = root.querySelector("#replace-file");
    var button = root.querySelector("#start-replace");
    var queue = root.querySelector("#replace-queue");
    var context = {
      accountId: root.dataset.accountId,
      integrity: root.dataset.integrity || "sha256",
      contentVersion: root.dataset.contentVersion,
      deferred: false,
      // Reload so the processing status (and later the new scan) shows.
      onDone: function () { window.setTimeout(function () { window.location.reload(); }, 1200); }
    };
    recover(context, queue,
      function (e) { return e.page_id === pageId; },
      function (e) { return e.name + " (replacement)"; });
    button.addEventListener("click", function () {
      var file = input.files && input.files[0];
      if (!file) { input.focus(); return; }
      button.disabled = true;
      var view = row(queue, file.name + " (replacement)");
      uploadOne(context, file, { page_id: pageId }, view).catch(function (error) {
        view.set(error.offerDeferred ? "Your processing allowance is used up, so the page cannot be replaced now." : error.message, "danger");
      }).then(function () {
        button.disabled = false;
        input.value = "";
      });
    });
  }

  // Signing out clears this browser's pending uploads and their photos.
  document.addEventListener("submit", function (event) {
    var form = event.target;
    if (form && form.getAttribute && form.getAttribute("action") === "/auth/logout") {
      try { window.localStorage.removeItem(STORAGE_KEY); } catch (e) { /* storage disabled */ }
      if (window.indexedDB) window.indexedDB.deleteDatabase(DB_NAME);
    }
  }, true);

  function scan() {
    init(document.getElementById("uploader"));
    initReplace(document.getElementById("replacer"));
  }
  document.addEventListener("DOMContentLoaded", scan);
  document.addEventListener("htmx:afterSettle", scan);
})();
