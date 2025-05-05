import os
import re
from collections import defaultdict
from pprint import pprint

import tree_sitter
import tree_sitter_solidity
from tree_sitter import Tree


def check_and_normalize_path(base_relative_path, target_path, directory_path):
    """
    Check if the target path exists and normalize it to have the same root as the base relative path.

    Args:
        base_relative_path (str): The base relative path.
        target_path (str): The target path to check and normalize.

    Returns:
        str: The normalized relative path if the target exists, otherwise None.
    """
    abs_root = os.getcwd()
    if "./" in target_path:
        os.chdir(os.path.dirname(base_relative_path))
    else:
        os.chdir(os.path.dirname(directory_path))
    if not os.path.exists(target_path):
        os.chdir(abs_root)
        return None

    target_abs_path = os.path.abspath(target_path)
    rel_path = os.path.relpath(target_abs_path, abs_root)
    os.chdir(abs_root)  # Change back to the original directory
    return rel_path


class CallGraphBuilder:
    def __init__(self):
        self.parser = tree_sitter.Parser()
        self.languages = {}
        self.function_definitions = defaultdict(
            list
        )  # Maps func_name -> [(file, range, abs_path)]
        self.function_calls = defaultdict(list)  # Maps caller -> list of callees
        self.function_bodies = {}  # Maps func_name -> body
        self.file_references = defaultdict(list)  # Maps rel_path -> list of imports
        self.current_recursive_path = []
        self.call_graph = {}

    def load_language(self, language_name, language):
        """Load a language from a compiled .so file"""
        self.languages[language_name] = language
        return language

    def detect_language(self, filename):
        """Simple language detection based on file extension"""
        ext = os.path.splitext(filename)[1].lower()

        if ext == ".sol":
            return "solidity"
        else:
            return None

    def get_query_for_language(self, lang):
        """Return the appropriate query for finding functions and calls in each language"""

        if lang == "solidity":
            # Solidity query
            return """
            ; Import directives
            (import_directive
                (string) @import.package)
            ; Function definitions
            (function_definition
              name: (identifier) @function.name
            )
            (function_body) @function.body
            (function_definition) @function.def
            ; Function calls
            (call_expression
              function: (identifier) @function.call)
            (call_expression
              function: (member_expression
                property: (identifier) @function.call))
            """
        else:
            # Generic fallback
            return """
            (function_definition
              name: (_) @function.def)
            (call_expression
              function: (_) @function.call)
            """

    def parse_file(self, file_path, directory_path):
        """Parse a file and extract function definitions and calls"""
        language_name = self.detect_language(file_path)
        if not language_name or language_name not in self.languages:
            print(f"Unsupported language for file: {file_path}")
            return

        language = self.languages[language_name]
        self.parser.set_language(language)

        with open(file_path, "rb") as f:
            source_code = f.read()

        tree = self.parser.parse(source_code)
        query_string = self.get_query_for_language(language_name)
        query = language.query(query_string)

        captures = query.captures(tree.root_node)
        # First pass: collect all function definitions
        current_function_stack = []
        pack = []

        for node, capture_name in captures:
            func_name = node.text.decode("utf8")
            # print(f"Node: {func_name}, Capture: {capture_name}")

            if capture_name == "import.package":
                func_name = func_name.replace('"', "").replace("'", "")
                fp = check_and_normalize_path(file_path, func_name, directory_path)
                if fp != None:
                    self.file_references[file_path].append(fp)
            if capture_name == "function.name":
                start_point = node.start_point
                end_point = node.parent.end_point
                if self.function_definitions.get(func_name):
                    self.function_definitions[func_name].append(
                        (file_path, (start_point, end_point))
                    )
                else:
                    self.function_definitions[func_name] = [
                        (
                            file_path,
                            (start_point, end_point),
                        )
                    ]

                # Process function body for nested function calls
                parent_node = node.parent
                if current_function_stack:
                    caller = current_function_stack[-1]
                    self.function_calls[caller].append(func_name)
                    self.graph.add_edge(caller, func_name)

                current_function_stack.append(func_name)
                self.process_function_body(parent_node, func_name, file_path, query)
                current_function_stack.pop()

    def process_function_body(self, func_node, func_name, file_path, query):
        """Process a function body to find calls to other functions"""
        # Find all function calls within this function body
        captures = query.captures(func_node)
        # if not any(capture_name == "function.body" for _, capture_name in captures):
        #     del self.function_definitions[func_name][-1]
        #     return

        for node, capture_name in captures:
            if capture_name == "function.call":
                callee = node.text.decode("utf8")
                if callee != func_name:  # Avoid self-calls if desired
                    self.function_calls[func_name].append((file_path, callee))
            if capture_name == "function.def":
                # Store the function body for later use
                self.function_bodies[func_name] = (node.text.decode("utf8"),)

    def process_directory(self, directory_path, directory_name):
        """Process all supported files in a directory"""

        for root, _, files in os.walk(directory_path):
            for file in files:
                file_path = os.path.join(root, file)
                print(f"Processing file: {file_path}")
                if self.detect_language(file_path):
                    self.parse_file(file_path, directory_path)
        for root, _, files in os.walk(directory_path):
            for file in files:
                file_path = os.path.join(root, file)
                if self.detect_language(file_path):
                    print(f"building file: {file_path}")
                    relative_path = os.path.relpath(file_path, directory_path)
                    target_path = os.path.join(
                        ".idea/to_solve/", directory_name, relative_path
                    )
                    os.makedirs(os.path.dirname(target_path), exist_ok=True)
                    with open(target_path, "w+") as f:
                        f.write(self.build_call_graph(file_path))

    def build_call_graph(self, file_path):
        """Build the call graph from the collected function definitions and calls"""
        print(file_path)
        if self.call_graph.get(file_path):
            print('("Already built")->')
            return self.call_graph[file_path]

        else:
            with open(file_path) as fi:
                source_code = fi.read()
            if (
                self.file_references[file_path] != []
                or self.function_definitions != None
            ):
                for fp in self.file_references[file_path]:
                    if fp in self.current_recursive_path:
                        continue
                    if not self.call_graph.get(fp):
                        self.current_recursive_path.append(fp)
                        self.call_graph[fp] = self.build_call_graph(fp)
                        print(f"call graph of {fp} created")
                        source_code = (
                            source_code
                            + f"\n ---- the following code is imported from file_name: {fp} ---- \n"
                            + self.call_graph[fp]
                        )

            # Remove all // line comments
            # Remove all /* block comments */
            source_code = re.sub(r"/\*[\s\S]*?\*/", "", source_code)
            source_code = re.sub(r"//.*", "", source_code)

            return source_code


# Example usage
if __name__ == "__main__":
    builder = CallGraphBuilder()

    # Load your languages (paths to compiled .so files)
    SOL_LAN = tree_sitter_solidity.get_language()
    builder.load_language("solidity", SOL_LAN)

    # Process a directory or specific files
    for dir in os.listdir(".idea/cloned_repos/"):
        if dir != "2022-05-rubicon":
            continue
        os.makedirs(".idea/to_solve/" + dir, exist_ok=True)

        builder.process_directory(".idea/cloned_repos/2022-05-rubicon/", dir)

    # OR process individual files

    # builder.parse_file("./test/contracts/RubiconRouter.sol")

    # Print the call graph
    # builder.print_call_graph()

    # Visualize the graph
    # builder.visualize_call_graph("call_graph.png")

    # Export to DOT format for better visualization with Graphviz
    # builder.export_call_graph("call_graph.dot")
