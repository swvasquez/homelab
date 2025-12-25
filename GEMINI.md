When reviewing and updating requested playbooks in the `playbook` folder
- Provide accurate, descriptive names to each task
- Use fully qualified module names for tasks commands (e.g., `ansibile.builtins.apt` instead of `apt`) 
- Provide a thorough description of the file in the form of a file header
- Use true and false values instead of yes and no for boolean fields
- Format consistently, including newlines between components
- Use `become_exe: sudo.ws` when `become: true`
- Add tasks, when missing, to clean up any temporary files created when downloading files from the internet
- Ensure installed tools are usable by all users
- All vars should be explicitly listed in the playbook with dummy values provided
- Use double quotation marks when possible
- Target line widths to be 100 characters or less (when possible)
- Run `just lint` and resolve any linting issues that arise at the end

When reviewing and updating `README.md`
- Make sure it indicates that code has been generated with AI assistance

Additionally, for any request
- Do not concatenate files
- Do not create new files such as unit tests (unless explicitly asked)
