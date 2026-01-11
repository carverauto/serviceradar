/**
 * JDM Editor Component
 *
 * Wraps the GoRules DecisionGraph editor for visual rule editing.
 * Uses JdmConfigProvider + DecisionGraph from @gorules/jdm-editor.
 *
 * Note: phoenix_react_server expects a named export called "Component"
 */
import React, { useState, useCallback } from 'react';
import { JdmConfigProvider, DecisionGraph } from '@gorules/jdm-editor';
import '@gorules/jdm-editor/dist/style.css';

/**
 * Creates an empty JDM definition with a basic structure
 */
function createEmptyDefinition() {
  return {
    nodes: [
      {
        id: 'input',
        type: 'inputNode',
        position: { x: 100, y: 200 },
        name: 'Input'
      },
      {
        id: 'output',
        type: 'outputNode',
        position: { x: 600, y: 200 },
        name: 'Output'
      }
    ],
    edges: []
  };
}

/**
 * Main JDM Editor Component
 *
 * Props:
 * - definition: The JDM JSON definition to edit
 * - readOnly: If true, the editor is read-only
 *
 * phoenix_react_server expects a named export called "Component"
 */
export function Component({ definition = null, readOnly = false }) {
  const [localDefinition, setLocalDefinition] = useState(() =>
    definition || createEmptyDefinition()
  );

  const handleChange = useCallback((newDefinition) => {
    setLocalDefinition(newDefinition);
    // Dispatch custom event for LiveView to pick up
    if (typeof window !== 'undefined') {
      window.dispatchEvent(new CustomEvent('jdm-editor:change', {
        detail: { definition: newDefinition }
      }));
    }
  }, []);

  return (
    <div className="h-full w-full">
      <JdmConfigProvider>
        <DecisionGraph
          value={localDefinition}
          onChange={handleChange}
          disabled={readOnly}
        />
      </JdmConfigProvider>
    </div>
  );
}

// Also export as default for direct imports
export default Component;
