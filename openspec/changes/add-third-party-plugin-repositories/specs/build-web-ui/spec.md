## ADDED Requirements

### Requirement: Plugin Repository Selector On Agent Plugin Settings
Settings → Agents → Plugins MUST present the plugin catalog source as a dropdown of stored
repositories rather than a free-form URL field, and MUST offer adding a new repository from within
that dropdown.

#### Scenario: Dropdown lists enabled repositories with the built-in default preselected
- **GIVEN** an administrator opens Settings → Agents → Plugins
- **WHEN** the catalog source control renders
- **THEN** it is a dropdown listing every enabled repository
- **AND** the built-in first-party repository is preselected
- **AND** no free-form repository URL text field is presented

#### Scenario: Add New opens a modal
- **GIVEN** the catalog source dropdown is open
- **WHEN** the administrator chooses the `… Add New` option
- **THEN** a modal opens for entering the repository name, URL, signing key id, signing public key,
  index asset name, and an optional access token
- **AND** the dropdown returns to its previous selection if the modal is dismissed

#### Scenario: Saving a repository loads its catalog
- **GIVEN** the add-repository modal is filled with a valid repository
- **WHEN** the administrator saves
- **THEN** the modal closes
- **AND** the new repository is selected in the dropdown
- **AND** the plugin catalog reloads from that repository

#### Scenario: Invalid repository is reported in the modal
- **GIVEN** the add-repository modal is submitted with a malformed URL or a missing signing key
- **WHEN** the administrator saves
- **THEN** the modal stays open with the field-level errors shown
- **AND** no repository is created

#### Scenario: Repositories can be edited and removed
- **GIVEN** a stored third-party repository
- **WHEN** the administrator edits or removes it from the plugins settings surface
- **THEN** the change is applied
- **AND** the dropdown reflects it without a full page reload

#### Scenario: Built-in repository cannot be edited or removed from the UI
- **GIVEN** the built-in first-party repository is selected
- **WHEN** the administrator views its controls
- **THEN** edit and remove are not offered
- **AND** an enable/disable control is offered

#### Scenario: Users without repository management permission see a read-only selector
- **GIVEN** a user with `plugins.view` but not `plugins.repositories.manage`
- **WHEN** the plugins settings page renders
- **THEN** the dropdown lists repositories and allows switching the viewed catalog
- **AND** the `… Add New` option, edit, and remove controls are not offered
