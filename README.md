# CS312minecraft-server
# Automated Minecraft Server Deployment on AWS

An infrastructure as code pipeline that provisions, configures, and deploys a Minecraft: Java Edition server on AWS EC2. The entire process is automated with Terraform, Ansible, and GitHub Actions, triggered on every push to `main`. No manual interaction with the AWS Management Console is required after initial setup.

## Background

This project automates the manual EC2 deployment from Course Project Part 1. The original setup involved logging into the AWS Console, launching an instance, SSHing in, installing Java, downloading the Minecraft `.jar`, configuring `systemd`, and so on. Everything that was done by hand is now done by code.

The pipeline uses three tools, each with a distinct role:

- **Terraform** provisions the AWS infrastructure (EC2 instance, security group, key pair).
- **Ansible** configures the instance over SSH (installs Docker, pulls the Minecraft image, runs the container).
- **GitHub Actions** orchestrates the whole pipeline so it runs automatically on every push.

The Minecraft server itself runs inside a Docker container using the `itzg/minecraft-server` image, which handles EULA acceptance, Java versioning, and graceful shutdown signals.

## Architecture

```mermaid
flowchart TD
    A[Developer pushes to main] --> B[GitHub Actions workflow starts]
    B --> C[Configure AWS credentials]
    C --> D[Clean up existing resources]
    D --> E[Terraform Init and Apply]
    E --> F[EC2 instance, Security Group, Key Pair created]
    F --> G[Capture EC2 public IP]
    G --> H[Install Ansible on runner]
    H --> I[Write SSH keys to runner]
    I --> J[Generate Ansible inventory with EC2 IP]
    J --> K[Wait for SSH to become available]
    K --> L[Run Ansible playbook]
    L --> M[Install Docker]
    M --> N[Pull itzg/minecraft-server image]
    N --> O[Run container with restart policy]
    O --> P[Server reachable on port 25565]
```

## Requirements

To run the pipeline you need:

- A GitHub account and a fork or clone of this repository
- An AWS account (this project was developed against AWS Academy Learner Lab)
- An SSH key pair generated with `ssh-keygen -t ed25519`

To test locally (optional) you need the following installed on your machine:

| Tool | Version | Purpose |
| ---- | ------- | ------- |
| Terraform | 1.5+ | Provision AWS resources |
| AWS CLI | 2.x | Manage AWS credentials and resources |
| Ansible | 2.14+ | Configure the EC2 instance (Linux/WSL only) |
| Git | any recent version | Push code and trigger the workflow |

Ansible does not run natively on Windows, so local Ansible testing requires WSL or a Linux VM. The GitHub Actions runner is Ubuntu and runs Ansible without issue.

## Setup

### 1. Generate an SSH key pair

```bash
ssh-keygen -t ed25519 -f ~/.ssh/minecraft -C "minecraft-server"
```

This creates `~/.ssh/minecraft` (private key) and `~/.ssh/minecraft.pub` (public key). The private key never leaves your machine or GitHub Secrets. The public key is uploaded to AWS by Terraform.

### 2. Configure GitHub Secrets

In your GitHub repository, go to **Settings → Secrets and variables → Actions** and add the following secrets:

| Secret Name | Value |
| ----------- | ----- |
| `AWS_ACCESS_KEY_ID` | From your Learner Lab AWS Details panel |
| `AWS_SECRET_ACCESS_KEY` | From your Learner Lab AWS Details panel |
| `AWS_SESSION_TOKEN` | From your Learner Lab AWS Details panel |
| `SSH_PRIVATE_KEY` | Contents of `~/.ssh/minecraft` |
| `SSH_PUBLIC_KEY` | Contents of `~/.ssh/minecraft.pub` |

The three AWS secrets expire whenever your Learner Lab session ends and need to be updated at the start of each new session. The SSH secrets only need to be set once.

When pasting the private key, include the `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----` lines and preserve all line breaks.

## Running the Pipeline

Once secrets are configured, the pipeline runs automatically on every push to the `main` branch:

```bash
git add .
git commit -m "Deploy"
git push
```

To trigger a deployment without changing any files:

```bash
git commit --allow-empty -m "Trigger deployment"
git push
```

You can monitor the run under the **Actions** tab of your GitHub repository.

### What the Workflow Does

The workflow runs the following stages in order:

1. **Checkout repository** — pulls the latest code onto the runner.
2. **Configure AWS credentials** — exports the Learner Lab credentials as environment variables for the rest of the run.
3. **Clean up existing resources** — terminates any leftover EC2 instances tagged `minecraft-server`, then deletes the old security group and key pair. This step exists because Terraform state is not persisted between GitHub Actions runs (each run starts on a fresh ephemeral runner with no state file). Without this cleanup, every subsequent push would fail with `InvalidGroup.Duplicate` and `InvalidKeyPair.Duplicate` errors. Production deployments would solve this with an S3 remote state backend, but for a project that does not need persistent state, cleanup before apply is a simpler approach.
4. **Setup Terraform** — installs Terraform on the runner.
5. **Terraform Init** — downloads the AWS provider plugin.
6. **Terraform Apply** — creates the EC2 instance, security group, and key pair. The SSH ingress rule is set to `0.0.0.0/0` for the duration of the run so the GitHub Actions runner can reach the instance.
7. **Get EC2 Public IP** — captures Terraform's `minecraft_server_ip` output as an environment variable for later steps.
8. **Install Ansible** — installs Ansible and the `community.docker` collection on the runner.
9. **Setup SSH keys** — writes both keys to `~/.ssh/` on the runner with appropriate permissions.
10. **Generate inventory** — writes the EC2 IP and SSH key path into `ansible/inventory.ini`.
11. **Wait for SSH** — polls port 22 every 10 seconds for up to 5 minutes until SSH becomes available, since EC2 instances take a minute or two to boot fully even after Terraform reports them as running.
12. **Run Ansible playbook** — connects to the instance and runs three tasks: install Docker, start the Docker service, and pull and run the `itzg/minecraft-server` container with `restart_policy: unless-stopped` and a volume mount at `/opt/minecraft/data` for world persistence.

### Auto-Restart Behavior

The container's `restart_policy: unless-stopped` means Docker will automatically restart the Minecraft server if the container crashes or the EC2 instance reboots. This satisfies the assignment's auto-restart requirement and also handles graceful shutdown correctly (something the original `systemd` based setup from Part 1 had issues with).

## Connecting to the Server

After the workflow completes, capture the public IP from the workflow logs (look for the `Get EC2 Public IP` step or the Terraform output) and verify the server is reachable:

```bash
nmap -sV -Pn -p T:25565 <PUBLIC_IP>
```

The expected output is:

```
PORT      STATE SERVICE    VERSION
25565/tcp open  minecraft  Minecraft 26.1.2 (Protocol: 127, Message: A Minecraft Server, Users: 0/20)
```

If the port shows `closed`, wait another minute or two and try again. The Minecraft server takes a moment to initialize the world and bind to port 25565 even after the Docker container starts.

## Repository Structure

```
.
├── .github/
│   └── workflows/
│       └── deploy.yml          GitHub Actions pipeline definition
├── ansible/
│   └── playbook.yml            Configures the EC2 instance, installs Docker, runs container
├── terraform/
│   ├── main.tf                 EC2 instance, security group, key pair, AMI data source
│   ├── variables.tf            Input variable declarations
│   ├── outputs.tf              Exports the public IP
│   └── providers.tf            AWS provider configuration
├── .gitignore                  Prevents committing state files, credentials, and keys
└── README.md
```

The Ansible inventory is generated at runtime by the workflow, so it does not live in the repo.

## References

- [Terraform AWS Provider documentation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Terraform Get Started Tutorial](https://developer.hashicorp.com/terraform/tutorials/aws-get-started)
- [Ansible documentation](https://docs.ansible.com/ansible/latest/index.html)
- [community.docker Ansible collection](https://docs.ansible.com/ansible/latest/collections/community/docker/index.html)
- [itzg/minecraft-server Docker image](https://github.com/itzg/docker-minecraft-server)
- [GitHub Actions documentation](https://docs.github.com/en/actions)
- [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials)
- [AWS CLI documentation](https://docs.aws.amazon.com/cli/)
