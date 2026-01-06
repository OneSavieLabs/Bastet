import os
import re
from collections import defaultdict
from typing import Dict, List, Optional

import tree_sitter
import tree_sitter_solidity
from tree_sitter import Language, Query, QueryCursor


class SourceBundler:
    """
    Multi-language source code analyzer that builds dependency graphs and
    concatenates imported code for comprehensive analysis.

    Supports any language with tree-sitter grammar. Currently configured for:
    - Solidity (.sol)

    Can be extended to support Python, JavaScript, TypeScript, Rust, etc.
    """

    def __init__(self, languages_to_load: Optional[List[str]] = None):
        """
        Initialize the analyzer with specified languages.

        Args:
            languages_to_load: List of language names to load.
                             If None, loads Solidity by default.
                             Options: ['solidity', 'python', 'javascript', etc.]
        """
        self.parser = tree_sitter.Parser()
        self.languages: Dict[str, Language] = {}

        if languages_to_load is None:
            languages_to_load = ["solidity"]

        self._load_languages(languages_to_load)

        # Tracks which files import which other files
        self.imported_libraries = defaultdict(
            list
        )  # Maps file_path -> list of imported files

        # Tracks the complete dependency stack for each file (all transitive dependencies)
        self.dependency_stacks = defaultdict(
            set
        )  # Maps file_path -> set of all dependencies

        # Caches the concatenated source code for each file
        self.concatenated_sources = {}  # Maps file_path -> concatenated source code

    def _load_languages(self, language_names: List[str]) -> None:
        """
        Initialize and load the specified language parsers.

        Args:
            language_names: List of languages to load (e.g., ['solidity', 'python'])
        """
        for lang in language_names:
            if lang == "solidity":
                self.languages["solidity"] = Language(tree_sitter_solidity.language())
            # Add more languages as needed:
            # elif lang == 'python':
            #     self.languages['python'] = Language(tree_sitter_python.language())
            # elif lang == 'javascript':
            #     self.languages['javascript'] = Language(tree_sitter_javascript.language())
            else:
                print(f"Warning: Language '{lang}' not implemented yet")

    def _detect_language(self, filename: str) -> Optional[str]:
        """Determine the programming language based on file extension."""
        extension = os.path.splitext(filename)[1].lower()

        # Map file extensions to language names
        extension_map = {
            ".sol": "solidity",
            # Add more as needed:
            # '.py': 'python',
            # '.js': 'javascript',
            # '.ts': 'typescript',
            # '.rs': 'rust',
            # '.go': 'go',
        }

        return extension_map.get(extension)

    def _get_import_query(self, language: str) -> str:
        """
        Return the tree-sitter query for finding import statements.

        Each language has different import syntax, so we need specific queries.
        """
        if language == "solidity":
            return """
            ; Import directives
            (import_directive
                (string) @import.package)
            """
        # Add more languages as needed:
        # elif language == "python":
        #     return """
        #     ; Python imports
        #     (import_statement
        #         name: (dotted_name) @import.package)
        #     (import_from_statement
        #         module_name: (dotted_name) @import.package)
        #     """
        # elif language == "javascript" or language == "typescript":
        #     return """
        #     ; JavaScript/TypeScript imports
        #     (import_statement
        #         source: (string) @import.package)
        #     """
        else:
            raise NotImplementedError(f"Language '{language}' not supported yet")

    def _normalize_import_path(
        self, source_file: str, import_path: str, project_root: str
    ) -> Optional[str]:
        """
        Resolve and normalize an import path relative to the project structure.

        Args:
            source_file: The file containing the import statement
            import_path: The path specified in the import statement
            project_root: The root directory of the project

        Returns:
            Normalized path if the file exists, None otherwise
        """
        # Determine the base directory for resolving the import
        if "./" in import_path or import_path.startswith("../"):
            # Relative import - resolve from source file's directory
            base_dir = os.path.dirname(source_file)
        else:
            # Absolute import - resolve from project root
            base_dir = project_root

        # Resolve the import path
        resolved_path = os.path.normpath(os.path.join(base_dir, import_path))
        # Check if the import target exists
        if not os.path.exists(resolved_path):
            return None

        return resolved_path

    def _extract_imports(self, file_path: str, project_root: str) -> None:
        """
        Parse a source file and extract all import statements.

        Args:
            file_path: Path to the file to analyze
            project_root: Root directory of the project
        """
        language_name = self._detect_language(file_path)
        if not language_name or language_name not in self.languages:
            print(f"Unsupported language for file: {file_path}")
            return

        language = self.languages[language_name]
        self.parser.language = language

        # Read and parse the source file
        with open(file_path, "rb") as f:
            source_code = f.read()

        tree = self.parser.parse(source_code)

        # Query for import statements
        query_string = self._get_import_query(language_name)
        query = Query(language, query_string)
        query_cursor = QueryCursor(query)
        matches = query_cursor.matches(tree.root_node)

        # Process each import found
        for match in matches:
            match_keys = list(match[1].keys())

            if match_keys[0] == "import.package":
                # Extract the import path from the matched node
                import_path = (
                    match[1]["import.package"][0]
                    .text.decode("utf8")
                    .replace('"', "")
                    .replace("'", "")
                )

                # Normalize and verify the import path
                normalized_import_path = self._normalize_import_path(
                    file_path, import_path, project_root
                )

                if normalized_import_path:
                    self.imported_libraries[file_path].append(normalized_import_path)

    def bundle_project(self, project_root: str) -> Dict:
        """
        Analyze all supported source files in a project directory.

        Args:
            project_root: Root directory of the project to analyze
        """
        # First pass: extract all import relationships
        for root, _, files in os.walk(project_root):
            for filename in files:
                file_path = os.path.join(root, filename)
                file_path = os.path.normpath(file_path)
                if self._detect_language(file_path):
                    self._extract_imports(file_path, project_root)
        for root, _, files in os.walk(project_root):
            for file in files:
                file_path = os.path.join(root, file)
                file_path = os.path.normpath(file_path)
                if self._detect_language(file_path):
                    self._build_concatenated_source(file_path)
        return self.concatenated_sources

    def _build_concatenated_source(self, file_path: str) -> str:
        """
        Build a concatenated source file with all dependencies included.

        Recursively includes all imported files to create a single comprehensive
        source file for analysis. Handles circular dependencies by tracking visited files.

        Args:
            file_path: Path to the file to process

        Returns:
            Concatenated source code including all dependencies
        """
        # Return cached result if available
        if file_path in self.concatenated_sources:
            return self.concatenated_sources[file_path]

        # Track files we've already processed to avoid infinite recursion
        visited_files = set([file_path])

        # Read the main source file
        with open(file_path) as f:
            main_source = f.read()

        # Build the complete dependency stack
        if self.imported_libraries[file_path]:
            # Recursively process all imports
            for imported_file in self.imported_libraries[file_path]:
                self.concatenated_sources[imported_file] = (
                    self._build_concatenated_source(imported_file)
                )
                if imported_file not in visited_files:
                    visited_files.update(self.dependency_stacks[imported_file])

            # Concatenate all imported source code
            for dependency in visited_files:
                if dependency == file_path:
                    continue

                with open(dependency) as f:
                    imported_source = f.read()

                # Add separator comment and append the imported code
                main_source += (
                    f"====== Code imported from: {dependency} ======" + imported_source
                )

        # Remove comments from the final concatenated source
        main_source = self._remove_comments(main_source)

        # Cache the dependency stack for this file
        self.dependency_stacks[file_path] = visited_files

        return main_source

    def _remove_comments(self, source_code: str) -> str:
        """
        Remove single-line and multi-line comments from source code.

        Args:
            source_code: The source code to clean

        Returns:
            Source code with comments removed
        """
        # Remove multi-line comments /* ... */
        source_code = re.sub(r"/\*[\s\S]*?\*/", "", source_code)

        # Remove single-line comments // ...
        source_code = re.sub(r"//.*", "", source_code)

        return source_code


# Example usage:
if __name__ == "__main__":
    # Example 1: Analyze Solidity project (default)

    bundler = SourceBundler()
    bundled_sources = bundler.bundle_project("path/to/solidity/project")
