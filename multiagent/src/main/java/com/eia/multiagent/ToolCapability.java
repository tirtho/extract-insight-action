package com.eia.multiagent;

/** Description of one worker tool and its Foundry binding. */
public record ToolCapability(String name, String description, String bindingReference) {

    public ToolCapability {
        name = name == null ? "" : name;
        description = description == null ? "" : description;
        bindingReference = bindingReference == null ? "" : bindingReference;
    }

    public String toPromptLine() {
        StringBuilder value = new StringBuilder(name);
        if (!description.isBlank()) value.append(" - ").append(description);
        if (!bindingReference.isBlank()) value.append(" [binding: ").append(bindingReference).append(']');
        return value.toString();
    }
}
