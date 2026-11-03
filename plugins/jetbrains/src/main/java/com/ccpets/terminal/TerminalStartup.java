package com.ccpets.terminal;

import com.intellij.openapi.project.Project;
import com.intellij.openapi.startup.StartupActivity;

/** Also starts the bridge for terminals opened before this plugin was installed. */
@SuppressWarnings("deprecation")
public final class TerminalStartup implements StartupActivity.DumbAware {
    @Override public void runActivity(Project project) {
        TerminalBridge.getInstance().start();
    }
}
