package com.ccpets.terminal;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.intellij.ide.plugins.IdeaPluginDescriptor;
import com.intellij.ide.plugins.PluginManagerCore;
import com.intellij.openapi.Disposable;
import com.intellij.openapi.application.ApplicationInfo;
import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.application.ModalityState;
import com.intellij.openapi.application.PathManager;
import com.intellij.openapi.diagnostic.Logger;
import com.intellij.openapi.fileEditor.FileEditorManager;
import com.intellij.openapi.fileEditor.OpenFileDescriptor;
import com.intellij.openapi.extensions.PluginId;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.project.ProjectManager;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.openapi.wm.IdeFocusManager;
import com.intellij.openapi.wm.ToolWindow;
import com.intellij.openapi.wm.ToolWindowManager;
import com.intellij.openapi.wm.WindowManager;
import com.intellij.platform.eel.provider.EelProviderUtil;
import com.intellij.platform.eel.provider.LocalEelDescriptor;
import com.intellij.terminal.frontend.editor.TerminalViewVirtualFile;
import com.intellij.terminal.frontend.toolwindow.TerminalToolWindowTab;
import com.intellij.terminal.frontend.toolwindow.TerminalToolWindowTabsManager;
import com.intellij.terminal.frontend.toolwindow.TerminalToolWindowTabsManagerKt;
import com.intellij.terminal.frontend.view.TerminalView;
import com.intellij.ui.AppIcon;
import com.intellij.ui.content.Content;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import org.jetbrains.plugins.terminal.session.TerminalStartupOptions;

import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/** One authenticated loopback endpoint per IDE process; disposed on plugin unload. */
public final class TerminalBridge implements Disposable {
    private static final Logger LOG = Logger.getInstance(TerminalBridge.class);
    private static final Gson JSON = new Gson();
    public final String instanceID = UUID.randomUUID().toString();
    private final String token = UUID.randomUUID() + "-" + UUID.randomUUID();
    private HttpServer server;
    private ThreadPoolExecutor workers;
    private Path registration;
    private volatile boolean disposed;

    public static TerminalBridge getInstance() {
        return ApplicationManager.getApplication().getService(TerminalBridge.class);
    }

    public synchronized boolean start() {
        if (disposed || !System.getProperty("os.name", "").startsWith("Mac")) return false;
        if (server != null) return true;
        try {
            Path directory = Path.of(System.getProperty("user.home"), "Library", "Application Support",
                                     "CC Pets", "ide-instances");
            Files.createDirectories(directory);
            if (Files.isSymbolicLink(directory)) throw new IOException("Invalid bridge directory");
            Files.setPosixFilePermissions(directory, PosixFilePermissions.fromString("rwx------"));
            server = HttpServer.create(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 8);
            workers = new ThreadPoolExecutor(1, 2, 30, TimeUnit.SECONDS, new ArrayBlockingQueue<>(16), task -> {
                Thread thread = new Thread(task, "CC Pets Terminal Bridge");
                thread.setDaemon(true);
                return thread;
            });
            server.setExecutor(workers);
            server.createContext("/", this::handle);
            server.start();
            JsonObject record = status();
            record.addProperty("port", server.getAddress().getPort());
            record.addProperty("token", token);
            record.addProperty("appPath", Path.of(PathManager.getHomePath()).getParent().toString());
            record.addProperty("configPath", PathManager.getConfigPath());
            record.addProperty("pluginsPath", PathManager.getPluginsPath());
            registration = directory.resolve(instanceID + ".json");
            Path temporary = Files.createTempFile(directory, ".registration-", ".tmp",
                PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")));
            try {
                Files.writeString(temporary, JSON.toJson(record));
                Files.move(temporary, registration, StandardCopyOption.ATOMIC_MOVE);
            } finally {
                Files.deleteIfExists(temporary);
            }
            return true;
        } catch (Exception error) {
            LOG.warn("Could not start CC Pets terminal bridge", error);
            stop();
            return false;
        }
    }

    /** CC Pets compares this with the version on disk to detect a pending restart. */
    private static String pluginVersion() {
        IdeaPluginDescriptor descriptor = PluginManagerCore.getPlugin(PluginId.getId("com.ccpets.terminal"));
        return descriptor != null && descriptor.getVersion() != null ? descriptor.getVersion() : "unknown";
    }

    private JsonObject status() {
        JsonObject record = new JsonObject();
        record.addProperty("schemaVersion", 1);
        record.addProperty("pluginVersion", pluginVersion());
        record.addProperty("instanceID", instanceID);
        record.addProperty("pid", ProcessHandle.current().pid());
        record.addProperty("ideVersion", ApplicationInfo.getInstance().getFullVersion());
        return record;
    }

    private void handle(HttpExchange exchange) throws IOException {
        try (exchange) {
            String authorization = exchange.getRequestHeaders().getFirst("Authorization");
            if (!"POST".equals(exchange.getRequestMethod()) ||
                exchange.getRequestHeaders().containsKey("Origin") || authorization == null ||
                !MessageDigest.isEqual(("Bearer " + token).getBytes(StandardCharsets.UTF_8),
                                       authorization.getBytes(StandardCharsets.UTF_8))) {
                reply(exchange, 403, Map.of("error", "unauthorized"));
                return;
            }
            String path = exchange.getRequestURI().getPath();
            if ("/status".equals(path)) {
                reply(exchange, 200, status());
                return;
            }
            if (!"/focus".equals(path)) {
                reply(exchange, 404, Map.of("error", "unknown_route"));
                return;
            }
            byte[] body = exchange.getRequestBody().readNBytes(4097);
            if (body.length > 4096) {
                reply(exchange, 413, Map.of("error", "request_too_large"));
                return;
            }
            try {
                JsonObject request = JsonParser.parseString(new String(body, StandardCharsets.UTF_8)).getAsJsonObject();
                String terminalID = string(request, "terminalID");
                String tty = string(request, "tty").replaceFirst("^/dev/", "");
                if (!(terminalID.matches("[a-fA-F0-9-]{36}") || tty.matches("ttys[0-9]{1,8}"))) {
                    reply(exchange, 400, Map.of("error", "invalid_target"));
                    return;
                }
                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
                List<Target> targets = snapshot();
                List<Target> matches = new ArrayList<>();
                for (Target target : targets) {
                    if (System.nanoTime() > deadline) throw new java.util.concurrent.TimeoutException();
                    if (!terminalID.isEmpty()) {
                        if (terminalID.equals(target.terminalID)) matches.add(target);
                    } else if (tty.equals(ttyForProcess(target.pid))) {
                        matches.add(target);
                    }
                }
                if (matches.size() != 1) {
                    reply(exchange, matches.isEmpty() ? 404 : 409,
                          Map.of("error", matches.isEmpty() ? "terminal_not_found" : "ambiguous_target"));
                    return;
                }
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) throw new java.util.concurrent.TimeoutException();
                boolean focused = focus(matches.getFirst(), deadline).get(remaining, TimeUnit.NANOSECONDS);
                reply(exchange, focused ? 200 : 409, Map.of("focused", focused));
            } catch (java.util.concurrent.TimeoutException error) {
                reply(exchange, 503, Map.of("error", "ide_busy"));
            } catch (IllegalArgumentException | IllegalStateException error) {
                reply(exchange, 400, Map.of("error", "invalid_request"));
            } catch (Exception error) {
                LOG.warn("CC Pets terminal focus failed", error);
                reply(exchange, 500, Map.of("error", "focus_failed"));
            }
        }
    }

    private static String string(JsonObject object, String key) {
        return object.has(key) && object.get(key).isJsonPrimitive() ? object.get(key).getAsString() : "";
    }

    /** Exactly one of tab (Terminal tool window) or file (moved to an editor tab) is set. */
    private record Target(Project project, TerminalToolWindowTab tab, VirtualFile file, TerminalView view,
                          Long pid, String terminalID) {}

    private static void addTarget(List<Target> targets, Project project, TerminalToolWindowTab tab,
                                  VirtualFile file, TerminalView view) {
        var options = view.getStartupOptionsDeferred();
        if (!options.isCompleted() || options.isCancelled()) return;
        TerminalStartupOptions startup = options.getCompleted();
        targets.add(new Target(project, tab, file, view, startup.getPid(),
            startup.getEnvVariables().getOrDefault("CC_PETS_IDE_TERMINAL_ID", "")));
    }

    /**
     * Terminals shown in the editor area. Two mechanisms exist:
     * - "Move to Editor" (2026.2+) opens a TerminalViewVirtualFile.
     * - "Open as Editor Tab" (2026.3+) moves the tool window Content itself into a platform
     *   editor tab. The Content is read through editorContent() and mapped back with
     *   getTerminalTab(Content).
     */
    private static void addEditorTargets(List<Target> targets, Project project) {
        FileEditorManager editors = FileEditorManager.getInstance(project);
        for (VirtualFile file : editors.getOpenFiles()) {
            try {
                if (file instanceof TerminalViewVirtualFile terminal) {
                    addTarget(targets, project, null, file, terminal.getTab().getView());
                    continue;
                }
                Content content = editorContent(project, file);
                TerminalToolWindowTab tab = content == null ? null : TerminalToolWindowTabsManagerKt.getTerminalTab(content);
                if (tab != null) addTarget(targets, project, null, file, tab.getView());
            } catch (LinkageError | RuntimeException error) {
                // Internal editor-tab API changed: tool window terminals keep working.
                LOG.debug("Terminal editor tab skipped", error);
            }
        }
    }

    private static final String EDITOR_TAB_FILE = "com.intellij.openapi.wm.impl.tabInEditor.ToolWindowEditorTabFile";
    private static final String EDITOR_TAB_MANAGER = "com.intellij.openapi.wm.impl.tabInEditor.ToolWindowEditorTabManager";

    /**
     * The tool window Content shown by a 2026.3 "Open as Editor Tab" file:
     * ToolWindowEditorTabManager.getInstance(project).getSession(file).getContent().
     * All three are public, but the classes only exist from 2026.3, hence reflection.
     */
    private static Content editorContent(Project project, VirtualFile file) {
        if (!EDITOR_TAB_FILE.equals(file.getClass().getName())) return null;
        try {
            Class<?> managerClass = Class.forName(EDITOR_TAB_MANAGER, false, file.getClass().getClassLoader());
            Object manager = managerClass.getMethod("getInstance", Project.class).invoke(null, project);
            Object session = managerClass.getMethod("getSession", file.getClass()).invoke(manager, file);
            if (session == null) return null;
            Object content = session.getClass().getMethod("getContent").invoke(session);
            return content instanceof Content value ? value : null;
        } catch (ReflectiveOperationException | LinkageError error) {
            LOG.debug("Terminal editor tab content unavailable", error);
            return null;
        }
    }

    private List<Target> snapshot() throws Exception {
        CompletableFuture<List<Target>> result = new CompletableFuture<>();
        ApplicationManager.getApplication().invokeLater(() -> {
            if (disposed || result.isDone()) return;
            try {
                List<Target> targets = new ArrayList<>();
                for (Project project : ProjectManager.getInstance().getOpenProjects()) {
                    if (project.isDisposed() ||
                        !(EelProviderUtil.getEelDescriptor(project) instanceof LocalEelDescriptor)) continue;
                    // Editor-area terminals first; a moved tab must not also match as a tool window tab.
                    int firstEditorTarget = targets.size();
                    addEditorTargets(targets, project);
                    Set<TerminalView> inEditor = new HashSet<>();
                    for (Target target : targets.subList(firstEditorTarget, targets.size())) inEditor.add(target.view);
                    for (TerminalToolWindowTab tab : TerminalToolWindowTabsManager.getInstance(project).getTabs()) {
                        if (!inEditor.contains(tab.getView())) addTarget(targets, project, tab, null, tab.getView());
                    }
                }
                result.complete(targets);
            } catch (Throwable error) {
                result.completeExceptionally(error);
            }
        }, ModalityState.nonModal());
        try {
            return result.get(800, TimeUnit.MILLISECONDS);
        } finally {
            result.cancel(false);
        }
    }

    private static String ttyForProcess(Long pid) throws Exception {
        if (pid == null || pid <= 0) return "";
        Process process = new ProcessBuilder("/bin/ps", "-p", Long.toString(pid), "-o", "tty=").start();
        try {
            if (!process.waitFor(150, TimeUnit.MILLISECONDS)) return "";
            return new String(process.getInputStream().readNBytes(128), StandardCharsets.UTF_8).trim();
        } finally {
            if (process.isAlive()) process.destroyForcibly();
        }
    }

    private CompletableFuture<Boolean> focus(Target target, long deadline) {
        CompletableFuture<Boolean> result = new CompletableFuture<>();
        ApplicationManager.getApplication().invokeLater(() -> {
            try {
                if (disposed || target.project.isDisposed() || System.nanoTime() > deadline) {
                    result.complete(false);
                    return;
                }
                if (target.file != null) {
                    result.complete(focusEditor(target));
                    return;
                }
                Content content = target.tab.getContent();
                ToolWindow window = ToolWindowManager.getInstance(target.project).getToolWindow("Terminal");
                if (content.getManager() == null || window == null ||
                    !TerminalToolWindowTabsManager.getInstance(target.project).getTabs().contains(target.tab)) {
                    result.complete(false);
                    return;
                }
                var frame = WindowManager.getInstance().getFrame(target.project);
                if (frame != null) AppIcon.getInstance().requestFocus(frame);
                window.activate(() -> {
                    try {
                        if (disposed || target.project.isDisposed() || content.getManager() == null ||
                            System.nanoTime() > deadline) {
                            result.complete(false);
                            return;
                        }
                        content.getManager().setSelectedContent(content, true);
                        IdeFocusManager.getInstance(target.project)
                            .requestFocus(target.tab.getView().getPreferredFocusableComponent(), true);
                        result.complete(true);
                    } catch (RuntimeException error) {
                        result.completeExceptionally(error);
                    }
                }, true, true);
            } catch (RuntimeException error) {
                result.completeExceptionally(error);
            }
        }, ModalityState.nonModal());
        return result;
    }

    /** Runs on the EDT. Selects the editor tab (in whichever window holds it) and focuses its input. */
    private static boolean focusEditor(Target target) {
        FileEditorManager editors = FileEditorManager.getInstance(target.project);
        if (!editors.isFileOpen(target.file)) return false;
        var frame = WindowManager.getInstance().getFrame(target.project);
        if (frame != null) AppIcon.getInstance().requestFocus(frame);
        // Reuses the tab wherever it is open, including a detached editor window.
        new OpenFileDescriptor(target.project, target.file).navigate(true);
        var component = target.view.getPreferredFocusableComponent();
        var window = javax.swing.SwingUtilities.getWindowAncestor(component);
        if (window != null) window.toFront();
        IdeFocusManager.getInstance(target.project).requestFocus(component, true);
        return true;
    }

    private static void reply(HttpExchange exchange, int code, Object body) throws IOException {
        byte[] bytes = JSON.toJson(body).getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        exchange.getResponseHeaders().set("Cache-Control", "no-store");
        exchange.sendResponseHeaders(code, bytes.length);
        exchange.getResponseBody().write(bytes);
    }

    private synchronized void stop() {
        if (server != null) server.stop(0);
        server = null;
        if (workers != null) workers.shutdownNow();
        workers = null;
        if (registration != null) {
            try { Files.deleteIfExists(registration); }
            catch (IOException error) { LOG.warn("Could not remove CC Pets registration", error); }
        }
    }

    @Override public void dispose() {
        disposed = true;
        stop();
    }
}
