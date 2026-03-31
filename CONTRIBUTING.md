# Contributing to Homecast

Thanks for your interest in contributing to Homecast Community Edition.

## Getting Started

1. Fork the repo and clone it locally
2. Follow the [build instructions](README.md#option-2-build-from-source) to get a working build
3. Create a branch for your changes

## Development

The project has two main parts:

- **Mac app** (`app-ios-macos/`) — Swift/SwiftUI, Mac Catalyst
- **Web app** (`app-web/`, separate repo: [parob/homecast-web](https://github.com/parob/homecast-web)) — React/TypeScript/Vite

### Web App Development

```bash
cd app-web
npm install
npm run dev    # Starts dev server on port 8080
```

### Mac App Development

Open `app-ios-macos/Homecast.xcodeproj` in Xcode and build for Mac Catalyst.

## Pull Requests

1. Open an issue first to discuss what you'd like to change
2. Keep PRs focused — one feature or fix per PR
3. Make sure the build passes: `cd app-web && npm run build`
4. Write a clear description of what changed and why

## Code Style

- TypeScript: follow existing patterns in the codebase
- Swift: follow existing patterns, use standard Swift conventions
- No unnecessary dependencies

## Reporting Issues

Use the [issue templates](https://github.com/parob/homecast/issues/new/choose) for bug reports and feature requests.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
