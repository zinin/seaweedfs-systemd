@Grab(group='org.jsoup', module='jsoup', version='1.15.3')
import org.jsoup.Jsoup

// Step 1: Determine the latest release number
def githubUrl = "https://github.com/seaweedfs/seaweedfs/releases/latest"
def doc = Jsoup.connect(githubUrl).get()
def latestRelease = doc.select("a[href*='/releases/tag/']").first().text()

println "Latest release: $latestRelease"

// Step 2: Download the latest release
def downloadUrl = "https://github.com/seaweedfs/seaweedfs/releases/download/${latestRelease}/linux_amd64_full.tar.gz"
def tarFile = "linux_amd64_full.tar.gz"

println "Downloading $downloadUrl..."
def process = new ProcessBuilder("curl", "-L", "-o", tarFile, downloadUrl).start()
process.waitFor()

if (process.exitValue() != 0) {
    println "Failed to download the release."
    System.exit(1)
}

// Step 3: Extract the executable file 'weed'
println "Extracting $tarFile..."
process = new ProcessBuilder("tar", "-xzf", tarFile, "weed").start()
process.waitFor()

if (process.exitValue() != 0) {
    println "Failed to extract the archive."
    System.exit(1)
}

// Verify the extracted 'weed' executable
process = new ProcessBuilder("./weed").start()
process.waitFor()

// Step 4: Create an empty file named help.txt
def helpFile = new File("help.txt")
helpFile.text = ""

// Step 5: Run 'weed help [command]' for each command and append output to help.txt
def commands = [
        "backup", "filer", "filer.backup", "filer.meta.backup", "filer.remote.gateway",
        "filer.remote.sync", "filer.sync", "iam", "master", "master.follower", "mount",
        "mq.broker", "s3", "server", "volume", "webdav"
]

commands.each { command ->
    println "Running 'weed help $command'..."
    process = new ProcessBuilder("./weed", "help", command).redirectErrorStream(true).start()
    process.waitFor()

    def output = process.text
    helpFile << "=== Command: weed help $command ===\n"
    helpFile << output
    helpFile << "\n\n"
}

println "help.txt has been created with the output of all commands."