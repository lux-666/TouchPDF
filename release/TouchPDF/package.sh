#!/bin/zsh
set -euo pipefail
task_source_dir="${0:A:h}"
task_output_dir="$task_source_dir/dist"
zsh "$task_source_dir/build.sh" "$task_output_dir"
task_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_source_dir/Info.plist")
task_archive_name="TouchPDF-$task_version-macos-arm64.zip"
/usr/bin/codesign --verify --deep --strict "$task_output_dir/TouchPDF.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$task_output_dir/TouchPDF.app" "$task_output_dir/$task_archive_name"
(cd "$task_output_dir" && /usr/bin/shasum -a 256 "$task_archive_name" > SHA256SUMS.txt)
print "Release: $task_output_dir/$task_archive_name"
