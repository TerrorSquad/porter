package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

type StateManager struct{}

func (sm *StateManager) getStateFile(fileName string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".porter", "state.json")
}

func (sm *StateManager) LoadProgress(fileName string) int {
	stateFile := sm.getStateFile(fileName)
	if stateFile == "" {
		return 0
	}

	data, err := os.ReadFile(stateFile)
	if err != nil {
		return 0
	}

	var state map[string]int
	err = json.Unmarshal(data, &state)
	if err != nil {
		return 0
	}

	if idx, ok := state[fileName]; ok {
		return idx
	}
	return 0
}

func (sm *StateManager) SaveProgress(fileName string, index int) {
	stateFile := sm.getStateFile(fileName)
	if stateFile == "" {
		return
	}

	// Ensure directory exists
	os.MkdirAll(filepath.Dir(stateFile), 0755)

	var state map[string]int
	data, err := os.ReadFile(stateFile)
	if err == nil {
		json.Unmarshal(data, &state)
	}

	if state == nil {
		state = make(map[string]int)
	}

	state[fileName] = index

	jsonData, _ := json.MarshalIndent(state, "", "  ")
	os.WriteFile(stateFile, jsonData, 0644)
}
