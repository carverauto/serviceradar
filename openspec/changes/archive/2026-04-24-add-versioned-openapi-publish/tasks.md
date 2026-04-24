## 1. Contract
- [x] 1.1 Define which ServiceRadar API surface is included in the first published OpenAPI artifact
- [x] 1.2 Define the stable versioned artifact path or publication target for developer portal consumption

## 2. Generation
- [x] 2.1 Ensure the selected OpenAPI document can be generated reproducibly from repository source
- [x] 2.2 Add version metadata so the artifact is aligned with the ServiceRadar platform/docs versioning model
- [x] 2.3 Expose SwaggerUI and Redoc routes for the Ash JSON:API OpenAPI surface without shadowing the router forward

## 3. Validation
- [x] 3.1 Add tests or CI checks that fail when the published OpenAPI artifact is missing or malformed
- [x] 3.2 Add tests or checks that ensure the artifact remains accessible through the supported publication path
- [x] 3.3 Add route coverage for the SwaggerUI and Redoc documentation endpoints

## 4. Handoff
- [x] 4.1 Document the artifact contract for developer portal ingestion
- [ ] 4.2 Open and merge the developer portal follow-on change only after this publishing contract is approved
