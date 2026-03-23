When reviewing, updating, or creating Ansible Playbooks in the `playbook` folder:
- Provide accurate, descriptive names to each task
- Use fully qualified module names for task commands (e.g., `ansible.builtin.apt` instead of `apt`)
- Provide a thorough description of the file in the form of a file header
- Use true and false values instead of yes and no for boolean fields
- Format consistently, including newlines between components
- Use `become_exe: sudo.ws` when `become: true`
- Add tasks, when missing, to clean up any temporary files created when downloading files from the internet
- Ensure installed tools are usable by all users
- All variables should be explicitly listed in the playbook with dummy values provided
- Target line widths to be 100 characters or less when possible
- Install packages via package manager

When asked for a full review of specified `playbook` files, for each file
- Review as described previously
- Organize into logical sections, with each section providing a thorough description via banner
- Add a description of all the input variables
- Fix any spelling, grammar, and formatting issues
- Ensure local network IP address variable values are read from `inventory.yml` or `group_vars` 
- **CRITICAL:** Run `just lint` and address any issues related to the specific file *ONLY AFTER* all other requirements have been addressed
- Update `README.md` and `justfile` to be consistent with changes

When reviewing or updating `README.md`
- Indicate that code has been generated with AI assistance
- Show expected `group_vars` and `inventory.yml` files with values specified using bracket notation `<VALUE>`

For YAML files (or templates for YAML files)
- Enclose values with quotes only when distinguishing between types (e.g., integer vs. string), distinguishing from YAML-reserved constructs, including special characters, or encasing strings containing Jinja templating variables
- Use single quotes for values unless escaping of characters is needed

For any request, unless explicitly asked
- Do not concatenate files
- Do not create new files such as unit tests
- **CRITICAL:** Consider reviewing files individually, if the number of files to be reviewed is too large

When attempting to answer a question or debug an issue
- Assume `kubectl` is available for you to run locally and is connected to the cluster you are debugging
- Query cluster services with `curl` (via IP or DNS) since the service and DNS load balancers are available on the LAN
- Prevent build up of artifacts by uninstalling any additional Docker images, Helm charts, Kubernetes manifests, etc., that are used purely for debugging
