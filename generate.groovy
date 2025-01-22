import java.nio.file.Files
import java.nio.file.Paths

// Define the project root directory
def projectDir = new File(".")

// Define the file extensions to include
def allowedExtensions = [".sh", ".service", ".yml", ".yaml", ".xsd", ".groovy", ".txt", ".md"]

// Exclude the script itself from processing
def scriptName = new File(getClass().protectionDomain.codeSource.location.path).name

// Exclude directories starting with a dot, and the build and gradle directories
def excludedDirs = [".gradle", ".idea", ".git", "build", "gradle"]

// StringBuilder to collect the result
def output = new StringBuilder()

// Function to mask password fields
def maskPasswords(String text) {
    // Regular expression to find password fields and their values
    def passwordPattern = ~/(?i)(password:\s*)(["'].*?["']|\S+)/
    // Replace the value with "password"
    return text.replaceAll(passwordPattern, '$1"password"')
}

// Recursive function to process files
def processFile(File file, List<String> allowedExtensions, String scriptName, List<String> excludedDirs, StringBuilder output) {
    // Log the start of processing for a file or directory
    println("Processing: ${file.path}")

    // Skip excluded directories
    if (file.isDirectory() && (file.name in excludedDirs || file.name.startsWith("."))) {
        println("Skipping directory: ${file.path} (excluded)")
        return
    }

    if (file.isDirectory()) {
        // Recursively process directories
        file.eachFile { processFile(it, allowedExtensions, scriptName, excludedDirs, output) }
    } else {
        // Check if the file has a supported extension and is not the script itself
        def fileName = file.name
        def extension = fileName.contains(".") ? fileName.substring(fileName.lastIndexOf(".")) : ""

        if (fileName == scriptName) {
            println("Skipping file: ${file.path} (this is the script itself)")
            return
        }

        if (!allowedExtensions.contains(extension)) {
            println("Skipping file: ${file.path} (unsupported extension: ${extension})")
            return
        }

        // Log the processing of the file
        println("Processing file: ${file.path}")

        output.append("File: ${file.path}\n")
        output.append("Content:\n```\n")

        // Read the file content
        def fileContent = file.text

        // If it's a YAML file, mask passwords
        if (extension in [".yml", ".yaml"]) {
            fileContent = maskPasswords(fileContent)
        }

        output.append(fileContent)
        output.append("\n```\n\n")
    }
}

// Start processing from the root directory
projectDir.eachFile { processFile(it, allowedExtensions, scriptName, excludedDirs, output) }

// Check for the presence of prompt.txt and add its content to the beginning
def promptFile = new File(projectDir, "prompt.txt")
def finalOutput = new StringBuilder()

if (promptFile.exists()) {
    println("Adding content from prompt.txt")
    finalOutput.append(promptFile.text) // Add the content of prompt.txt without a header
    finalOutput.append("\n\n")
} else {
    println("File prompt.txt not found, skipping")
}

finalOutput.append(output.toString())

// Save the result to a file
def outputFile = new File("project_code.txt")
outputFile.text = finalOutput.toString()

println("Final result saved to file: ${outputFile.path}")