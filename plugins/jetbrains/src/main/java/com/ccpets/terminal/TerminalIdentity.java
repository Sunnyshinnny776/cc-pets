package com.ccpets.terminal;

import com.intellij.openapi.project.Project;
import com.intellij.platform.eel.EelDescriptor;
import com.intellij.platform.eel.provider.LocalEelDescriptor;
import org.jetbrains.plugins.terminal.LocalTerminalCustomizer;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Identity belongs to a terminal, not its title, working directory, or active window. */
@SuppressWarnings("deprecation")
public final class TerminalIdentity extends LocalTerminalCustomizer {
    @Override public List<String> customizeCommandAndEnvironment(Project project, String directory,
            List<String> command, Map<String, String> environment, EelDescriptor descriptor) {
        if (!(descriptor instanceof LocalEelDescriptor)) return command;
        TerminalBridge bridge = TerminalBridge.getInstance();
        if (bridge.start()) {
            environment.put("CC_PETS_IDE_INSTANCE_ID", bridge.instanceID);
            environment.put("CC_PETS_IDE_TERMINAL_ID", UUID.randomUUID().toString());
        }
        return command;
    }
}
