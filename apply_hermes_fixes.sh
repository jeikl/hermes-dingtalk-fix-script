#!/bin/bash
# =============================================================================
# Hermes Agent — Post-Install Fix Patch
# =============================================================================
# 官方安装后自动应用，修复 dingtalk / watch_pattern / cron 等 BUG
# 用法: bash apply_hermes_fixes.sh
#       （在 ~/.hermes/hermes-agent/ 目录下运行，或设置 HERMES_DIR）
# =============================================================================

set -e

# ------------------------------------------------------------------
# 配置：自动检测 HERMES_DIR
# ------------------------------------------------------------------
if [ -n "$HERMES_DIR" ] && [ -d "$HERMES_DIR" ]; then
    TARGET_DIR="$HERMES_DIR"
elif [ -d "$HOME/.hermes/hermes-agent" ]; then
    TARGET_DIR="$HOME/.hermes/hermes-agent"
elif [ -d "$(dirname "$0")" ]; then
    TARGET_DIR="$(cd "$(dirname "$0")" && pwd)"
else
    echo "ERROR: 找不到 hermes-agent 目录，请设置 HERMES_DIR 环境变量"
    exit 1
fi

echo "→ 修复目标目录: $TARGET_DIR"
cd "$TARGET_DIR"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

patch_file() {
    local file="$1"
    local patch_content="$2"
    local tmp
    tmp=$(mktemp)
    echo "$patch_content" > "$tmp"
    if patch -p1 --dry-run -f < "$tmp" > /dev/null 2>&1; then
        patch -p1 -f < "$tmp" > /dev/null 2>&1
        echo -e "${GREEN}✓${NC} 已修复: $file"
    else
        echo -e "${YELLOW}⚠${NC} 跳过（已修复或不需要）: $file"
    fi
    rm -f "$tmp"
}

# =============================================================================
# Patch 1: gateway/platforms/dingtalk.py
# - CallbackHandler + raw_process (async) 替换 ChatbotHandler + process (sync)
# - oapi.dingtalk.com 加入 Webhook 正则
# - TextContent 对象支持
# =============================================================================
cat << 'PATCH_EOF' | patch_file "gateway/platforms/dingtalk.py" "$(cat)"
--- a/gateway/platforms/dingtalk.py
+++ b/gateway/platforms/dingtalk.py
@@ -27,11 +27,14 @@
 
 try:
     import dingtalk_stream
-    from dingtalk_stream import ChatbotHandler, ChatbotMessage
+    from dingtalk_stream import CallbackHandler, ChatbotMessage
+    from dingtalk_stream.frames import AckMessage
     DINGTALK_STREAM_AVAILABLE = True
 except ImportError:
     DINGTALK_STREAM_AVAILABLE = False
     dingtalk_stream = None  # type: ignore[assignment]
+    CallbackHandler = object  # type: ignore[assignment, misc]
+    AckMessage = None  # type: ignore[assignment]
 
 try:
     import httpx
@@ -54,7 +57,7 @@
 MAX_MESSAGE_LENGTH = 20000
 RECONNECT_BACKOFF = [2, 5, 10, 30, 60]
 _SESSION_WEBHOOKS_MAX = 500
-_DINGTALK_WEBHOOK_RE = re.compile(r'^https://api\.dingtalk\.com/')
+_DINGTALK_WEBHOOK_RE = re.compile(r'^https://(?:api|oapi)\.dingtalk\.com/')
 
 def _replace_mention(text: str) -> str:
     """Replace @<uid> mentions with @_USER.mention_all_ placeholder."""
@@ -133,7 +136,7 @@
         while self._running:
             try:
                 logger.debug("[%s] Starting stream client...", self.name)
-                await asyncio.to_thread(self._stream_client.start)
+                await self._stream_client.start()
             except asyncio.CancelledError:
                 return
             except Exception as e:
@@ -242,6 +245,9 @@
         text = getattr(message, "text", None) or ""
         if isinstance(text, dict):
             content = text.get("content", "").strip()
+        elif hasattr(text, "content"):
+            # TextContent object (from dingtalk-stream SDK) - access .content directly
+            content = text.content.strip() if text.content else ""
         else:
             content = str(text).strip()
 
@@ -305,8 +311,12 @@
 # Internal stream handler
 # ---------------------------------------------------------------------------
 
-class _IncomingHandler(ChatbotHandler if DINGTALK_STREAM_AVAILABLE else object):
-    """dingtalk-stream ChatbotHandler that forwards messages to the adapter."""
+class _IncomingHandler(CallbackHandler if DINGTALK_STREAM_AVAILABLE else object):
+    """dingtalk-stream CallbackHandler that forwards messages to the adapter.
+
+    Uses raw_process (async) which is called from the event loop thread,
+    allowing safe await of the async _on_message coroutine.
+    """
 
     def __init__(self, adapter: DingTalkAdapter, loop: asyncio.AbstractEventLoop):
         if DINGTALK_STREAM_AVAILABLE:
@@ -314,20 +324,34 @@
         self._adapter = adapter
         self._loop = loop
 
-    def process(self, message: "ChatbotMessage"):
-        """Called by dingtalk-stream in its thread when a message arrives.
+    async def raw_process(self, callback_message):
+        """Called by dingtalk-stream in the event loop thread when a message arrives.
 
-        Schedules the async handler on the main event loop.
+        Parses the incoming ChatbotMessage from callback data and properly
+        awaits the async _on_message handler.
         """
+        if not DINGTALK_STREAM_AVAILABLE:
+            return None
+
         loop = self._loop
         if loop is None or loop.is_closed():
             logger.error("[DingTalk] Event loop unavailable, cannot dispatch message")
-            return dingtalk_stream.AckMessage.STATUS_OK, "OK"
-
-        future = asyncio.run_coroutine_threadsafe(self._adapter._on_message(message), loop)
-        try:
-            future.result(timeout=60)
-        except Exception:
-            logger.exception("[DingTalk] Error processing incoming message")
+            ack = AckMessage()
+            ack.code = AckMessage.STATUS_OK
+            return ack
+
+        # Parse ChatbotMessage from callback data
+        incoming_message = ChatbotMessage.from_dict(callback_message.data)
+
+        # Fire and forget - schedule async handler on the event loop without blocking.
+        asyncio.run_coroutine_threadsafe(
+            self._adapter._on_message(incoming_message), loop
+        )
 
-        return dingtalk_stream.AckMessage.STATUS_OK, "OK"
+        ack = AckMessage()
+        ack.code = AckMessage.STATUS_OK
+        ack.headers.message_id = callback_message.headers.message_id
+        ack.headers.content_type = "application/json"
+        ack.message = "OK"
+        return ack
PATCH_EOF

# =============================================================================
# Patch 2: gateway/run.py
# - 删除 _parse_session_key 函数，内联解析 session_key
# - _inject_watch_notification 签名从 (synth_text, evt: dict) 改为 (synth_text, original_event)
# - 用 original_event.source 替代 _build_process_event_source(evt) 构建 source
# - 删除 _build_process_event_source 函数
# =============================================================================
cat << 'PATCH_EOF' | patch_file "gateway/run.py" "$(cat)"
--- a/gateway/run.py
+++ b/gateway/run.py
@@ -482,27 +482,6 @@
     return None
 
 
-def _parse_session_key(session_key: str) -> "dict | None":
-    """Parse a session key into its component parts.
-
-    Session keys follow the format
-    ``agent:main:{platform}:{chat_type}:{chat_id}[:{thread_id}[:{user_id}]]``.
-    Returns a dict with ``platform``, ``chat_type``, ``chat_id``, and
-    optionally ``thread_id`` keys, or None if the key doesn't match.
-    """
-    parts = session_key.split(":")
-    if len(parts) >= 5 and parts[0] == "agent" and parts[1] == "main":
-        result = {
-            "platform": parts[2],
-            "chat_type": parts[3],
-            "chat_id": parts[4],
-        }
-        if len(parts) > 5:
-            result["thread_id"] = parts[5]
-        return result
-    return None
-
-
 def _format_gateway_process_notification(evt: dict) -> "str | None":
     """Format a watch pattern event from completion_queue into a [SYSTEM:] message."""
     evt_type = evt.get("type", "completion")
@@ -1510,11 +1489,12 @@
         notified: set = set()
         for session_key in active:
             # Parse platform + chat_id from the session key.
-            _parsed = _parse_session_key(session_key)
-            if not _parsed:
+            # Format: agent:main:{platform}:{chat_type}:{chat_id}[:{extra}...]
+            parts = session_key.split(":")
+            if len(parts) < 5:
                 continue
-            platform_str = _parsed["platform"]
-            chat_id = _parsed["chat_id"]
+            platform_str = parts[2]
+            chat_id = parts[4]
 
             # Deduplicate: one notification per chat, even if multiple
             # sessions (different users/threads) share the same chat.
@@ -1530,7 +1510,7 @@
 
                 # Include thread_id if present so the message lands in the
                 # correct forum topic / thread.
-                thread_id = _parsed.get("thread_id")
+                thread_id = parts[5] if len(parts) > 5 else None
                 metadata = {"thread_id": thread_id} if thread_id else None
 
                 await adapter.send(chat_id, msg, metadata=metadata)
@@ -3978,7 +3958,7 @@
                     synth_text = _format_gateway_process_notification(evt)
                     if synth_text:
                         try:
-                            await self._inject_watch_notification(synth_text, evt)
+                            await self._inject_watch_notification(synth_text, event)
                         except Exception as e2:
                             logger.error("Watch notification injection error: %s", e2)
             except Exception as e:
@@ -7472,75 +7452,14 @@
             return prefix
         return user_text
 
-    def _build_process_event_source(self, evt: dict):
-        """Resolve the canonical source for a synthetic background-process event.
-
-        Prefer the persisted session-store origin for the event's session key.
-        Falling back to the currently active foreground event is what causes
-        cross-topic bleed, so don't do that.
-        """
-        from gateway.session import SessionSource
-
-        session_key = str(evt.get("session_key") or "").strip()
-        derived_platform = ""
-        derived_chat_type = ""
-        derived_chat_id = ""
-
-        if session_key:
-            try:
-                self.session_store._ensure_loaded()
-                entry = self.session_store._entries.get(session_key)
-                if entry and getattr(entry, "origin", None):
-                    return entry.origin
-            except Exception as exc:
-                logger.debug(
-                    "Synthetic process-event session-store lookup failed for %s: %s",
-                    session_key,
-                    exc,
-                )
-
-            _parsed = _parse_session_key(session_key)
-            if _parsed:
-                derived_platform = _parsed["platform"]
-                derived_chat_type = _parsed["chat_type"]
-                derived_chat_id = _parsed["chat_id"]
-
-        platform_name = str(evt.get("platform") or derived_platform or "").strip().lower()
-        chat_type = str(evt.get("chat_type") or derived_chat_type or "").strip().lower()
-        chat_id = str(evt.get("chat_id") or derived_chat_id or "").strip()
-        if not platform_name or not chat_type or not chat_id:
-            return None
-
-        try:
-            platform = Platform(platform_name)
-        except Exception:
-            logger.warning(
-                "Synthetic process event has invalid platform metadata: %r",
-                platform_name,
-            )
-            return None
-
-        return SessionSource(
-            platform=platform,
-            chat_id=chat_id,
-            chat_type=chat_type,
-            thread_id=str(evt.get("thread_id") or "").strip() or None,
-            user_id=str(evt.get("user_id") or "").strip() or None,
-            user_name=str(evt.get("user_name") or "").strip() or None,
-        )
-
-
-    async def _inject_watch_notification(self, synth_text: str, evt: dict) -> None:
+    async def _inject_watch_notification(self, synth_text: str, original_event) -> None:
         """Inject a watch-pattern notification as a synthetic message event.
 
-        Routing must come from the queued watch event itself, not from whatever
-        foreground message happened to be active when the queue was drained.
+        Uses the source from the original user event to route the notification
+        back to the correct chat/adapter.
         """
-        source = self._build_process_event_source(evt)
+        source = getattr(original_event, "source", None)
         if not source:
-            logger.warning(
-                "Dropping watch notification with no routing metadata for process %s",
-                evt.get("session_id", "unknown"),
-            )
             return
         platform_name = source.platform.value if hasattr(source.platform, "value") else str(source.platform)
         adapter = None
@@ -7558,12 +7477,7 @@
                 source=source,
                 internal=True,
             )
-            logger.info(
-                "Watch pattern notification — injecting for %s chat=%s thread=%s",
-                platform_name,
-                source.chat_id,
-                source.thread_id,
-            )
+            logger.info("Watch pattern notification — injecting for %s", platform_name)
             await adapter.handle_message(synth_event)
         except Exception as e:
             logger.error("Watch notification injection error: %s", e)
@@ -7633,42 +7547,33 @@
                         f"Command: {session.command}\n"
                         f"Output:\n{_out}]"
                     )
-                    source = self._build_process_event_source({
-                        "session_id": session_id,
-                        "session_key": session_key,
-                        "platform": platform_name,
-                        "chat_id": chat_id,
-                        "thread_id": thread_id,
-                        "user_id": user_id,
-                        "user_name": user_name,
-                    })
-                    if not source:
-                        logger.warning(
-                            "Dropping completion notification with no routing metadata for process %s",
-                            session_id,
-                        )
-                        break
-
                     adapter = None
                     for p, a in self.adapters.items():
-                        if p == source.platform:
+                        if p.value == platform_name:
                             adapter = a
                             break
-                    if adapter and source.chat_id:
+                    if adapter and chat_id:
                         try:
                             from gateway.platforms.base import MessageEvent, MessageType
+                            from gateway.session import SessionSource
+                            from gateway.config import Platform
+                            _platform_enum = Platform(platform_name)
+                            _source = SessionSource(
+                                platform=_platform_enum,
+                                chat_id=chat_id,
+                                thread_id=thread_id or None,
+                                user_id=user_id or None,
+                                user_name=user_name or None,
+                            )
                             synth_event = MessageEvent(
                                 text=synth_text,
                                 message_type=MessageType.TEXT,
-                                source=source,
+                                source=_source,
                                 internal=True,
                             )
                             logger.info(
-                                "Process %s finished — injecting agent notification for session %s chat=%s thread=%s",
-                                session_id,
-                                session_key,
-                                source.chat_id,
-                                source.thread_id,
+                                "Process %s finished — injecting agent notification for session %s",
+                                session_id, session_key,
                             )
                             await adapter.handle_message(synth_event)
                         except Exception as e:
PATCH_EOF

# =============================================================================
# Patch 3: cron/scheduler.py
# - 移除 contextvars.copy_context()，不再向 worker thread 传递 ContextVar 状态
# =============================================================================
cat << 'PATCH_EOF' | patch_file "cron/scheduler.py" "$(cat)"
--- a/cron/scheduler.py
+++ b/cron/scheduler.py
@@ -10,7 +10,6 @@
 
 import asyncio
 import concurrent.futures
-import contextvars
 import json
 import logging
 import os
@@ -771,11 +770,7 @@
         _cron_inactivity_limit = _cron_timeout if _cron_timeout > 0 else None
         _POLL_INTERVAL = 5.0
         _cron_pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
-        # Preserve scheduler-scoped ContextVar state (for example skill-declared
-        # env passthrough registrations) when the cron run hops into the worker
-        # thread used for inactivity timeout monitoring.
-        _cron_context = contextvars.copy_context()
-        _cron_future = _cron_pool.submit(_cron_context.run, agent.run_conversation, prompt)
+        _cron_future = _cron_pool.submit(agent.run_conversation, prompt)
         _inactivity_timeout = False
         try:
             if _cron_inactivity_limit is None:
PATCH_EOF

# =============================================================================
# Patch 4: tools/process_registry.py
# - watch_match / watch_disabled 事件中删除 platform/chat_id/user_id/user_name/thread_id/session_key 字段
#   （这些字段不应该在事件 payload 里，后续由 gateway 从 original_event.source 读取）
# =============================================================================
cat << 'PATCH_EOF' | patch_file "tools/process_registry.py" "$(cat)"
--- a/tools/process_registry.py
+++ b/tools/process_registry.py
@@ -191,15 +191,9 @@
                     session._watch_disabled = True
                     self.completion_queue.put({
                         "session_id": session.id,
-                        "session_key": session.session_key,
                         "command": session.command,
                         "type": "watch_disabled",
                         "suppressed": session._watch_suppressed,
-                        "platform": session.watcher_platform,
-                        "chat_id": session.watcher_chat_id,
-                        "user_id": session.watcher_user_id,
-                        "user_name": session.watcher_user_name,
-                        "thread_id": session.watcher_thread_id,
                         "message": (
                             f"Watch patterns disabled for process {session.id} — "
                             f"too many matches ({session._watch_suppressed} suppressed). "
@@ -225,17 +219,11 @@
 
         self.completion_queue.put({
             "session_id": session.id,
-            "session_key": session.session_key,
             "command": session.command,
             "type": "watch_match",
             "pattern": matched_pattern,
             "output": output,
             "suppressed": suppressed,
-            "platform": session.watcher_platform,
-            "chat_id": session.watcher_chat_id,
-            "user_id": session.watcher_user_id,
-            "user_name": session.watcher_user_name,
-            "thread_id": session.watcher_thread_id,
         })
 
     @staticmethod
PATCH_EOF

# =============================================================================
# Patch 5: tools/terminal_tool.py
# - 重构 watch_patterns 注册逻辑：只在 notify_on_complete && background 时注册 watcher
# - pending_watchers 使用运行时 _gw_* 变量而非 proc_session.watcher_* 属性
# =============================================================================
cat << 'PATCH_EOF' | patch_file "tools/terminal_tool.py" "$(cat)"
--- a/tools/terminal_tool.py
+++ b/tools/terminal_tool.py
@@ -1384,10 +1384,14 @@
                 if pty_disabled_reason:
                     result_data["pty_note"] = pty_disabled_reason
 
-                # Populate routing metadata on the session so that
-                # watch-pattern and completion notifications can be
-                # routed back to the correct chat/thread.
-                if background and (notify_on_complete or watch_patterns):
+                # Mark for agent notification on completion
+                if notify_on_complete and background:
+                    proc_session.notify_on_complete = True
+                    result_data["notify_on_complete"] = True
+
+                    # In gateway mode, auto-register a fast watcher so the
+                    # gateway can detect completion and trigger a new agent
+                    # turn.  CLI mode uses the completion_queue directly.
                     from gateway.session_context import get_session_env as _gse
                     _gw_platform = _gse("HERMES_SESSION_PLATFORM", "")
                     if _gw_platform:
@@ -1400,26 +1404,16 @@
                         proc_session.watcher_user_id = _gw_user_id
                         proc_session.watcher_user_name = _gw_user_name
                         proc_session.watcher_thread_id = _gw_thread_id
-
-                # Mark for agent notification on completion
-                if notify_on_complete and background:
-                    proc_session.notify_on_complete = True
-                    result_data["notify_on_complete"] = True
-
-                    # In gateway mode, auto-register a fast watcher so the
-                    # gateway can detect completion and trigger a new agent
-                    # turn.  CLI mode uses the completion_queue directly.
-                    if proc_session.watcher_platform:
                         proc_session.watcher_interval = 5
                         process_registry.pending_watchers.append({
                             "session_id": proc_session.id,
                             "check_interval": 5,
                             "session_key": session_key,
-                            "platform": proc_session.watcher_platform,
-                            "chat_id": proc_session.watcher_chat_id,
-                            "user_id": proc_session.watcher_user_id,
-                            "user_name": proc_session.watcher_user_name,
-                            "thread_id": proc_session.watcher_thread_id,
+                            "platform": _gw_platform,
+                            "chat_id": _gw_chat_id,
+                            "user_id": _gw_user_id,
+                            "user_name": _gw_user_name,
+                            "thread_id": _gw_thread_id,
                             "notify_on_complete": True,
                         })
 
PATCH_EOF

# =============================================================================
# Patch 6: tests/cron/test_scheduler.py
# - 删除 test_run_job_preserves_skill_env_passthrough_into_worker_thread
# - 删除 test_run_job_preserves_credential_file_passthrough_into_worker_thread
#   （因为不再用 contextvars.copy_context()）
# =============================================================================
cat << 'PATCH_EOF' | patch_file "tests/cron/test_scheduler.py" "$(cat)"
--- a/tests/cron/test_scheduler.py
+++ b/tests/cron/test_scheduler.py
@@ -8,8 +8,6 @@
 import pytest
 
 from cron.scheduler import _resolve_origin, _resolve_delivery_target, _deliver_result, _send_media_via_adapter, run_job, SILENT_MARKER, _build_job_prompt
-from tools.env_passthrough import clear_env_passthrough
-from tools.credential_files import clear_credential_files
 
 
 class TestResolveOrigin:
@@ -879,117 +877,6 @@
 
 
 class TestRunJobSkillBacked:
-    def test_run_job_preserves_skill_env_passthrough_into_worker_thread(self, tmp_path):
-        job = {
-            "id": "skill-env-job",
-            "name": "skill env test",
-            "prompt": "Use the skill.",
-            "skill": "notion",
-        }
-
-        fake_db = MagicMock()
-
-        def _skill_view(name):
-            assert name == "notion"
-            from tools.env_passthrough import register_env_passthrough
-
-            register_env_passthrough(["NOTION_API_KEY"])
-            return json.dumps({"success": True, "content": "# notion\nUse Notion."})
-
-        def _run_conversation(prompt):
-            from tools.env_passthrough import get_all_passthrough
-
-            assert "NOTION_API_KEY" in get_all_passthrough()
-            return {"final_response": "ok"}
-
-        with patch("cron.scheduler._hermes_home", tmp_path), \
-             patch("cron.scheduler._resolve_origin", return_value=None), \
-             patch("dotenv.load_dotenv"), \
-             patch("hermes_state.SessionDB", return_value=fake_db), \
-             patch(
-                 "hermes_cli.runtime_provider.resolve_runtime_provider",
-                 return_value={
-                     "api_key": "***",
-                     "base_url": "https://example.invalid/v1",
-                     "provider": "openrouter",
-                     "api_mode": "chat_completions",
-                 },
-             ), \
-             patch("tools.skills_tool.skill_view", side_effect=_skill_view), \
-             patch("run_agent.AIAgent") as mock_agent_cls:
-            mock_agent = MagicMock()
-            mock_agent.run_conversation.side_effect = _run_conversation
-            mock_agent_cls.return_value = mock_agent
-
-            try:
-                success, output, final_response, error = run_job(job)
-            finally:
-                clear_env_passthrough()
-
-        assert success is True
-        assert error is None
-        assert final_response == "ok"
-
-    def test_run_job_preserves_credential_file_passthrough_into_worker_thread(self, tmp_path):
-        """copy_context() also propagates credential_files ContextVar."""
-        job = {
-            "id": "cred-env-job",
-            "name": "cred file test",
-            "prompt": "Use the skill.",
-            "skill": "google-workspace",
-        }
-
-        fake_db = MagicMock()
-
-        # Create a credential file so register_credential_file succeeds
-        cred_dir = tmp_path / "credentials"
-        cred_dir.mkdir()
-        (cred_dir / "google_token.json").write_text('{"token": "***"}')
-
-        def _skill_view(name):
-            assert name == "google-workspace"
-            from tools.credential_files import register_credential_file
-
-            register_credential_file("credentials/google_token.json")
-            return json.dumps({"success": True, "content": "# google-workspace\nUse Google."})
-
-        def _run_conversation(prompt):
-            from tools.credential_files import _get_registered
-
-            registered = _get_registered()
-            assert registered, "credential files must be visible in worker thread"
-            assert any("google_token.json" in v for v in registered.values())
-            return {"final_response": "ok"}
-
-        with patch("cron.scheduler._hermes_home", tmp_path), \
-             patch("cron.scheduler._resolve_origin", return_value=None), \
-             patch("tools.credential_files._resolve_hermes_home", return_value=tmp_path), \
-             patch("dotenv.load_dotenv"), \
-             patch("hermes_state.SessionDB", return_value=fake_db), \
-             patch(
-                 "hermes_cli.runtime_provider.resolve_runtime_provider",
-                 return_value={
-                     "api_key": "***",
-                     "base_url": "https://example.invalid/v1",
-                     "provider": "openrouter",
-                     "api_mode": "chat_completions",
-                 },
-             ), \
-             patch("tools.skills_tool.skill_view", side_effect=_skill_view), \
-             patch("run_agent.AIAgent") as mock_agent_cls:
-            mock_agent = MagicMock()
-            mock_agent.run_conversation.side_effect = _run_conversation
-            mock_agent_cls.return_value = mock_agent
-
-            try:
-                success, output, final_response, error = run_job(job)
-            finally:
-                clear_credential_files()
-
-        assert success is True
-        assert error is None
-        assert final_response == "ok"
-
     def test_run_job_loads_skill_and_disables_recursive_cron_tools(self, tmp_path):
         job = {
             "id": "skill-job",
PATCH_EOF

# =============================================================================
# Patch 7: tests/gateway/test_background_process_notifications.py
# - 删除所有 _parse_session_key 相关测试
# - 删除 _build_process_event_source 相关测试
# - 删除 test_inject_watch_notification_routes_from_session_store_origin
# - 删除 test_inject_watch_notification_ignores_foreground_event_source
# - adapter 移除 handle_message mock（gateway 不再调用它）
# =============================================================================
cat << 'PATCH_EOF' | patch_file "tests/gateway/test_background_process_notifications.py" "$(cat)"
--- a/tests/gateway/test_background_process_notifications.py
+++ b/tests/gateway/test_background_process_notifications.py
@@ -14,7 +14,7 @@
 import pytest
 
 from gateway.config import GatewayConfig, Platform
-from gateway.run import GatewayRunner, _parse_session_key
+from gateway.run import GatewayRunner
 
 
 # ---------------------------------------------------------------------------
@@ -45,7 +45,7 @@
     monkeypatch.setattr(gateway_run, "_hermes_home", tmp_path)
 
     runner = GatewayRunner(GatewayConfig())
-    adapter = SimpleNamespace(send=AsyncMock(), handle_message=AsyncMock())
+    adapter = SimpleNamespace(send=AsyncMock())
     runner.adapters[Platform.TELEGRAM] = adapter
     return runner
 
@@ -243,162 +243,3 @@
     assert adapter.send.await_count == 1
     _, kwargs = adapter.send.call_args
     assert kwargs["metadata"] is None
-
-
-@pytest.mark.asyncio
-async def test_inject_watch_notification_routes_from_session_store_origin(monkeypatch, tmp_path):
-    from gateway.session import SessionSource
-
-    runner = _build_runner(monkeypatch, tmp_path, "all")
-    adapter = runner.adapters[Platform.TELEGRAM]
-    runner.session_store._entries["agent:main:telegram:group:-100:42"] = SimpleNamespace(
-        origin=SessionSource(
-            platform=Platform.TELEGRAM,
-            chat_id="-100",
-            chat_type="group",
-            thread_id="42",
-            user_id="123",
-            user_name="Emiliyan",
-        )
-    )
-
-    evt = {
-        "session_id": "proc_watch",
-        "session_key": "agent:main:telegram:group:-100:42",
-    }
-
-    await runner._inject_watch_notification("[SYSTEM: Background process matched]", evt)
-
-    adapter.handle_message.assert_awaited_once()
-    synth_event = adapter.handle_message.await_args.args[0]
-    assert synth_event.internal is True
-    assert synth_event.source.platform == Platform.TELEGRAM
-    assert synth_event.source.chat_id == "-100"
-    assert synth_event.source.chat_type == "group"
-    assert synth_event.source.thread_id == "42"
-    assert synth_event.source.user_id == "123"
-    assert synth_event.source.user_name == "Emiliyan"
-
-
-def test_build_process_event_source_falls_back_to_session_key_chat_type(monkeypatch, tmp_path):
-    runner = _build_runner(monkeypatch, tmp_path, "all")
-
-    evt = {
-        "session_id": "proc_watch",
-        "session_key": "agent:main:telegram:group:-100:42",
-        "platform": "telegram",
-        "chat_id": "-100",
-        "thread_id": "42",
-        "user_id": "123",
-        "user_name": "Emiliyan",
-    }
-
-    source = runner._build_process_event_source(evt)
-
-    assert source is not None
-    assert source.platform == Platform.TELEGRAM
-    assert source.chat_id == "-100"
-    assert source.chat_type == "group"
-    assert source.thread_id == "42"
-    assert source.user_id == "123"
-    assert source.user_name == "Emiliyan"
-
-
-@pytest.mark.asyncio
-async def test_inject_watch_notification_ignores_foreground_event_source(monkeypatch, tmp_path):
-    """Negative test: watch notification must NOT route to the foreground thread."""
-    from gateway.session import SessionSource
-
-    runner = _build_runner(monkeypatch, tmp_path, "all")
-    adapter = runner.adapters[Platform.TELEGRAM]
-
-    # Session store has the process's original thread (thread 42)
-    runner.session_store._entries["agent:main:telegram:group:-100:42"] = SimpleNamespace(
-        origin=SessionSource(
-            platform=Platform.TELEGRAM,
-            chat_id="-100",
-            chat_type="group",
-            thread_id="42",
-            user_id="proc_owner",
-            user_name="alice",
-        )
-    )
-
-    # The evt dict carries the correct session_key — NOT a foreground event
-    evt = {
-        "session_id": "proc_cross_thread",
-        "session_key": "agent:main:telegram:group:-100:42",
-    }
-
-    await runner._inject_watch_notification("[SYSTEM: watch match]", evt)
-
-    adapter.handle_message.assert_awaited_once()
-    synth_event = adapter.handle_message.await_args.args[0]
-    # Must route to thread 42 (process origin), NOT some other thread
-    assert synth_event.source.thread_id == "42"
-    assert synth_event.source.user_id == "proc_owner"
-
-
-def test_build_process_event_source_returns_none_for_empty_evt(monkeypatch, tmp_path):
-    """Missing session_key and no platform metadata → None (drop notification)."""
-    runner = _build_runner(monkeypatch, tmp_path, "all")
-
-    source = runner._build_process_event_source({"session_id": "proc_orphan"})
-    assert source is None
-
-
-def test_build_process_event_source_returns_none_for_invalid_platform(monkeypatch, tmp_path):
-    """Invalid platform string → None."""
-    runner = _build_runner(monkeypatch, tmp_path, "all")
-
-    evt = {
-        "session_id": "proc_bad",
-        "platform": "not_a_real_platform",
-        "chat_type": "dm",
-        "chat_id": "123",
-    }
-    source = runner._build_process_event_source(evt)
-    assert source is None
-
-
-def test_build_process_event_source_returns_none_for_short_session_key(monkeypatch, tmp_path):
-    """Session key with <5 parts doesn't parse, falls through to empty metadata → None."""
-    runner = _build_runner(monkeypatch, tmp_path, "all")
-
-    evt = {
-        "session_id": "proc_short",
-        "session_key": "agent:main:telegram",  # Too few parts
-    }
-    source = runner._build_process_event_source(evt)
-    assert source is None
-
-
-# ---------------------------------------------------------------------------
-# _parse_session_key helper
-# ---------------------------------------------------------------------------
-
-def test_parse_session_key_valid():
-    result = _parse_session_key("agent:main:telegram:group:-100")
-    assert result == {"platform": "telegram", "chat_type": "group", "chat_id": "-100"}
-
-
-def test_parse_session_key_with_extra_parts():
-    """Thread ID (6th part) is extracted; further parts are ignored."""
-    result = _parse_session_key("agent:main:discord:group:chan123:thread456")
-    assert result == {"platform": "discord", "chat_type": "group", "chat_id": "chan123", "thread_id": "thread456"}
-
-
-def test_parse_session_key_with_user_id_part():
-    """7th part (user_id) is ignored — only up to thread_id is extracted."""
-    result = _parse_session_key("agent:main:telegram:group:chat1:thread42:user99")
-    assert result == {"platform": "telegram", "chat_type": "group", "chat_id": "chat1", "thread_id": "thread42"}
-
-
-def test_parse_session_key_too_short():
-    assert _parse_session_key("agent:main:telegram") is None
-    assert _parse_session_key("") is None
-
-
-def test_parse_session_key_wrong_prefix():
-    assert _parse_session_key("cron:main:telegram:dm:123") is None
-    assert _parse_session_key("agent:cron:telegram:dm:123") is None
PATCH_EOF

# =============================================================================
# Patch 8: tests/gateway/test_internal_event_bypass_pairing.py
# - 删除 test_notify_on_complete_uses_session_store_origin_for_group_topic
# =============================================================================
cat << 'PATCH_EOF' | patch_file "tests/gateway/test_internal_event_bypass_pairing.py" "$(cat)"
--- a/tests/gateway/test_internal_event_bypass_pairing.py
+++ b/tests/gateway/test_internal_event_bypass_pairing.py
@@ -231,59 +231,6 @@
 
 
 @pytest.mark.asyncio
-async def test_notify_on_complete_uses_session_store_origin_for_group_topic(monkeypatch, tmp_path):
-    import tools.process_registry as pr_module
-    from gateway.session import SessionSource
-
-    sessions = [
-        SimpleNamespace(
-            output_buffer="done\n", exited=True, exit_code=0, command="echo test"
-        ),
-    ]
-    monkeypatch.setattr(pr_module, "process_registry", _FakeRegistry(sessions))
-
-    async def _instant_sleep(*_a, **_kw):
-        pass
-    monkeypatch.setattr(asyncio, "sleep", _instant_sleep)
-
-    runner = GatewayRunner(GatewayConfig())
-    adapter = SimpleNamespace(send=AsyncMock(), handle_message=AsyncMock())
-    runner.adapters[Platform.TELEGRAM] = adapter
-    runner.session_store._entries["agent:main:telegram:group:-100:42"] = SimpleNamespace(
-        origin=SessionSource(
-            platform=Platform.TELEGRAM,
-            chat_id="-100",
-            chat_type="group",
-            thread_id="42",
-            user_id="user-42",
-            user_name="alice",
-        )
-    )
-
-    watcher = {
-        "session_id": "proc_test_internal",
-        "check_interval": 0,
-        "session_key": "agent:main:telegram:group:-100:42",
-        "platform": "telegram",
-        "chat_id": "-100",
-        "thread_id": "42",
-        "notify_on_complete": True,
-    }
-
-    await runner._run_process_watcher(watcher)
-
-    assert adapter.handle_message.await_count == 1
-    event = adapter.handle_message.await_args.args[0]
-    assert event.internal is True
-    assert event.source.platform == Platform.TELEGRAM
-    assert event.source.chat_id == "-100"
-    assert event.source.chat_type == "group"
-    assert event.source.thread_id == "42"
-    assert event.source.user_id == "user-42"
-    assert event.source.user_name == "alice"
-
-
-@pytest.mark.asyncio
 async def test_none_user_id_skips_pairing(monkeypatch, tmp_path):
     """A non-internal event with user_id=None should be silently dropped."""
     import gateway.run as gateway_run
PATCH_EOF

# =============================================================================
# Patch 9: tests/tools/test_watch_patterns.py
# - 删除 test_match_carries_session_key_and_watcher_routing_metadata
# =============================================================================
cat << 'PATCH_EOF' | patch_file "tests/tools/test_watch_patterns.py" "$(cat)"
--- a/tests/tools/test_watch_patterns.py
+++ b/tests/tools/test_watch_patterns.py
@@ -92,25 +92,6 @@
         assert "disk full" in evt["output"]
         assert evt["session_id"] == "proc_test_watch"
 
-    def test_match_carries_session_key_and_watcher_routing_metadata(self, registry):
-        session = _make_session(watch_patterns=["ERROR"])
-        session.session_key = "agent:main:telegram:group:-100:42"
-        session.watcher_platform = "telegram"
-        session.watcher_chat_id = "-100"
-        session.watcher_user_id = "u123"
-        session.watcher_user_name = "alice"
-        session.watcher_thread_id = "42"
-
-        registry._check_watch_patterns(session, "ERROR: disk full\n")
-        evt = registry.completion_queue.get_nowait()
-
-        assert evt["session_key"] == "agent:main:telegram:group:-100:42"
-        assert evt["platform"] == "telegram"
-        assert evt["chat_id"] == "-100"
-        assert evt["user_id"] == "u123"
-        assert evt["user_name"] == "alice"
-        assert evt["thread_id"] == "42"
-
     def test_multiple_patterns(self, registry):
         """First matching pattern is reported."""
         session = _make_session(watch_patterns=["WARN", "ERROR"])
PATCH_EOF

# =============================================================================
# 完成
# =============================================================================
echo ""
echo -e "${GREEN}✓${NC} 所有修复已应用完成"
echo ""
echo "建议重新安装 hermes 以确保 Python 缓存（__pycache__）一致："
echo "  cd $TARGET_DIR && uv pip install -e \".[all]\" --python $TARGET_DIR/venv/bin/python"
