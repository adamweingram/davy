use std::collections::HashSet;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};

use anyhow::{Context, Result, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use chrono::Local;
use clap::{ArgAction, Args, Parser, Subcommand};
#[cfg(unix)]
use std::os::unix::fs::{FileTypeExt, MetadataExt};
#[cfg(unix)]
use users::os::unix::UserExt;
use users::{get_current_gid, get_current_uid, get_user_by_uid};

const DEFAULT_IMAGE: &str = "davy-sandbox:latest";
const CLAUDE_LINK_SCRIPT: &str = r#"set -e
mkdir -p /home/dev/.claude-auth/.claude
touch /home/dev/.claude-auth/.claude.json

if [ -e /home/dev/.claude ] && [ ! -L /home/dev/.claude ]; then
  rm -rf /home/dev/.claude
fi
if [ -e /home/dev/.claude.json ] && [ ! -L /home/dev/.claude.json ]; then
  rm -f /home/dev/.claude.json
fi

ln -sfn /home/dev/.claude-auth/.claude /home/dev/.claude
ln -sfn /home/dev/.claude-auth/.claude.json /home/dev/.claude.json
export CLAUDE_CONFIG_DIR=/home/dev/.claude

exec "$@""#;

const SSH_BOOTSTRAP_SCRIPT: &str = r#"set -e
if ! command -v sshd >/dev/null 2>&1; then
  echo "davy: sshd is not installed in image. Rebuild with the latest rocky.Dockerfile." >&2
  exit 1
fi

if ! command -v ps >/dev/null 2>&1; then
  echo "davy: 'ps' is required for remote IDE SSH helpers (VS Code and derivatives)." >&2
  echo "davy: rebuild with the latest rocky.Dockerfile." >&2
  exit 1
fi

if ! command -v flock >/dev/null 2>&1; then
  echo "davy: 'flock' is required for remote IDE SSH helpers (VS Code and derivatives)." >&2
  echo "davy: rebuild with the latest rocky.Dockerfile." >&2
  exit 1
fi

if [ -z "${DAVY_SSH_AUTH_KEYS_B64:-}" ]; then
  echo "davy: DAVY_SSH_AUTH_KEYS_B64 is missing." >&2
  exit 1
fi

mkdir -p /home/dev/.ssh
chmod 700 /home/dev/.ssh
if ! printf "%s" "$DAVY_SSH_AUTH_KEYS_B64" | base64 -d >/home/dev/.ssh/authorized_keys 2>/dev/null; then
  printf "%s" "$DAVY_SSH_AUTH_KEYS_B64" | base64 --decode >/home/dev/.ssh/authorized_keys
fi
if [ ! -s /home/dev/.ssh/authorized_keys ]; then
  echo "davy: decoded authorized_keys is empty." >&2
  exit 1
fi
chmod 600 /home/dev/.ssh/authorized_keys

sudo mkdir -p /run/sshd
if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
  sudo ssh-keygen -A >/dev/null
fi

sudo /usr/sbin/sshd \
  -o PermitRootLogin=no \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o ChallengeResponseAuthentication=no \
  -o PubkeyAuthentication=yes \
  -o AuthorizedKeysFile=.ssh/authorized_keys \
  -o PidFile=/tmp/davy-sshd.pid

exec "$@""#;

#[derive(Debug, Parser)]
#[command(
    name = "davy",
    about = "Docker-based sandbox runner for agent CLIs",
    version,
    args_conflicts_with_subcommands = true
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    #[command(flatten)]
    run: RunArgs,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Manage persistent auth state
    Auth {
        #[command(subcommand)]
        command: AuthCommands,
    },
}

#[derive(Debug, Subcommand)]
enum AuthCommands {
    /// Claude auth volume management
    Claude {
        #[command(subcommand)]
        command: ClaudeCommands,
    },
}

#[derive(Debug, Subcommand)]
enum ClaudeCommands {
    /// Delete the Claude auth volume
    Reset,
}

#[derive(Debug, Args)]
struct RunArgs {
    /// Mount project directory at /project
    #[arg(short = 'p', long = "project", value_name = "DIR")]
    project_dir: Option<PathBuf>,

    /// Container name
    #[arg(short = 'n', long = "name", value_name = "NAME")]
    name: Option<String>,

    /// Also mount host docker socket
    #[arg(long = "docker", action = ArgAction::SetTrue)]
    with_docker_sock: bool,

    /// Docker socket path to mount (defaults to DAVY_DOCKER_SOCK, DOCKER_HOST unix://, then /var/run/docker.sock)
    #[arg(long = "docker-sock", env = "DAVY_DOCKER_SOCK", value_name = "PATH")]
    docker_sock: Option<PathBuf>,

    /// Force rebuild of the image before running (pull + no cache)
    #[arg(long = "rebuild", action = ArgAction::SetTrue)]
    rebuild: bool,

    /// Do not build; fail if image is missing
    #[arg(long = "no-build", action = ArgAction::SetTrue)]
    no_build: bool,

    /// Do not remove the container on exit
    #[arg(long = "keep", action = ArgAction::SetTrue)]
    keep: bool,

    /// Publish host PORT to container port 22 (default: 222)
    #[arg(
        short = 's',
        long = "expose-ssh",
        num_args = 0..=1,
        default_missing_value = "222",
        value_name = "PORT",
        value_parser = clap::value_parser!(u16).range(1..)
    )]
    expose_ssh: Option<u16>,

    /// Additional environment variable in KEY=VALUE format (repeatable)
    #[arg(short = 'e', long = "env", value_name = "KEY=VALUE", action = ArgAction::Append)]
    extra_env: Vec<String>,

    /// Forward host environment variable by key name (repeatable)
    #[arg(long = "pass-env", value_name = "KEY", action = ArgAction::Append)]
    pass_env: Vec<String>,

    /// Mount host Pi auth
    #[arg(long = "auth-pi", alias = "pi-auth", action = ArgAction::SetTrue)]
    with_pi_auth: bool,

    /// Mount host Codex auth
    #[arg(long = "auth-codex", alias = "codex-auth", action = ArgAction::SetTrue)]
    with_codex_auth: bool,

    /// Mount host Gemini auth
    #[arg(long = "auth-gemini", alias = "gemini-auth", action = ArgAction::SetTrue)]
    with_gemini_auth: bool,

    /// Mount persistent Claude auth volume
    #[arg(long = "auth-claude", alias = "claude-auth", action = ArgAction::SetTrue)]
    with_claude_auth: bool,

    /// Enable all auth mounts (pi, codex, gemini, claude)
    #[arg(short = 'a', long = "auth-all", action = ArgAction::SetTrue)]
    auth_all: bool,

    /// Docker image tag
    #[arg(long = "image", env = "DAVY_IMAGE", default_value = DEFAULT_IMAGE)]
    image: String,

    /// Dockerfile to build (defaults to ~/.config/davy/rocky.Dockerfile, then ~/.config/davy/debian.Dockerfile)
    #[arg(long = "dockerfile", env = "DAVY_DOCKERFILE", value_name = "PATH")]
    dockerfile: Option<PathBuf>,

    /// Use Dockerfile from current directory instead of ~/.config/davy
    #[arg(long = "local-dockerfile", action = ArgAction::SetTrue)]
    local_dockerfile: bool,

    /// Additional docker run arguments (pass before --)
    #[arg(
        value_name = "DOCKER_ARG",
        allow_hyphen_values = true,
        value_terminator = "--"
    )]
    extra_docker_args: Vec<OsString>,

    /// Command to run inside the container (pass after --)
    #[arg(trailing_var_arg = true, value_name = "COMMAND")]
    cmd: Vec<OsString>,
}

struct RuntimeSettings {
    project_dir: PathBuf,
    dockerfile: PathBuf,
    context_dir: PathBuf,
    image: String,
    name: String,
    host_uid: u32,
    host_gid: u32,
    keep: bool,
    rebuild: bool,
    no_build: bool,
    docker_sock: Option<PathBuf>,
    docker_sock_gid: Option<u32>,
    expose_ssh: Option<u16>,
    with_claude_auth: bool,
    claude_auth_volume: String,
    extra_docker_args: Vec<OsString>,
    extra_env_args: Vec<OsString>,
    cmd: Vec<OsString>,
}

fn main() {
    if let Err(err) = try_main() {
        eprintln!("davy: {err:#}");
        std::process::exit(1);
    }
}

fn try_main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Some(Commands::Auth {
            command:
                AuthCommands::Claude {
                    command: ClaudeCommands::Reset,
                },
        }) => reset_claude_auth_volume(),
        None => run_container(cli.run),
    }
}

fn run_container(args: RunArgs) -> Result<()> {
    let mut settings = build_runtime_settings(args)?;

    maybe_build_image(&settings)?;

    if settings.with_claude_auth {
        ensure_claude_volume_ready(&settings)?;
    }

    if settings.expose_ssh.is_some() {
        let ssh_auth_content = collect_ssh_authorized_keys()?;
        let encoded = STANDARD.encode(ssh_auth_content);
        push_env(
            &mut settings.extra_env_args,
            format!("DAVY_SSH_AUTH_KEYS_B64={encoded}"),
        );
    }

    if settings.cmd.is_empty() {
        settings.cmd.push(OsString::from("bash"));
    }

    if settings.with_claude_auth {
        settings.cmd = wrap_bash_script(CLAUDE_LINK_SCRIPT, std::mem::take(&mut settings.cmd));
    }
    if settings.expose_ssh.is_some() {
        settings.cmd = wrap_bash_script(SSH_BOOTSTRAP_SCRIPT, std::mem::take(&mut settings.cmd));
    }

    if let Some(docker_sock) = settings.docker_sock.as_ref() {
        eprintln!(
            "davy: docker socket mounted from {}. Container can control host Docker.",
            docker_sock.display()
        );
        if let Some(gid) = settings.docker_sock_gid {
            eprintln!("davy: adding supplementary group {gid} for docker socket access.");
        }
    }
    if let Some(port) = settings.expose_ssh {
        eprintln!("davy: exposing host port {port} to container port 22.");
        eprintln!("davy: SSH login user is 'dev' (key auth only).");
    }
    if settings.with_claude_auth {
        eprintln!(
            "davy: Claude auth volume mounted at /home/dev/.claude-auth ({}).",
            settings.claude_auth_volume
        );
        eprintln!("davy: first use requires running 'claude login' in-container.");
    }

    let status = docker_run(&settings)?;
    if status.success() {
        return Ok(());
    }

    match status.code() {
        Some(code) => std::process::exit(code),
        None => bail!("docker run terminated by signal"),
    }
}

fn build_runtime_settings(args: RunArgs) -> Result<RuntimeSettings> {
    let host_uid = get_current_uid();
    let host_gid = get_current_gid();

    let project_dir = match args.project_dir {
        Some(path) => path,
        None => env::current_dir().context("failed to read current directory")?,
    };
    if !project_dir.is_dir() {
        bail!("project dir not found: {}", project_dir.display());
    }

    let dockerfile = resolve_dockerfile(args.dockerfile, args.local_dockerfile)?;
    if !dockerfile.is_file() {
        bail!("Dockerfile not found at: {}", dockerfile.display());
    }

    let context_dir = dockerfile
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));

    let with_pi_auth = args.with_pi_auth || args.auth_all;
    let with_codex_auth = args.with_codex_auth || args.auth_all;
    let with_gemini_auth = args.with_gemini_auth || args.auth_all;
    let with_claude_auth = args.with_claude_auth || args.auth_all;
    let allow_missing_auth = args.auth_all;

    let claude_auth_volume = env::var("DAVY_CLAUDE_AUTH_VOLUME")
        .unwrap_or_else(|_| format!("davy-claude-auth-{host_uid}-v1"));

    let home = home_dir()?;

    let mut extra_env_args = Vec::new();
    for kv in args.extra_env {
        push_env(&mut extra_env_args, kv);
    }
    for key in args.pass_env {
        let value = env::var(&key).unwrap_or_default();
        push_env(&mut extra_env_args, format!("{key}={value}"));
    }

    let mut extra_docker_args = args.extra_docker_args;
    if with_pi_auth {
        add_bind_mount(
            &mut extra_docker_args,
            &home.join(".pi/agent"),
            "/home/dev/.pi/agent",
            "Pi auth",
            allow_missing_auth,
        )?;
    }
    if with_codex_auth {
        if add_bind_mount(
            &mut extra_docker_args,
            &home.join(".codex"),
            "/home/dev/.codex",
            "Codex auth",
            allow_missing_auth,
        )? {
            push_env(
                &mut extra_env_args,
                "CODEX_HOME=/home/dev/.codex".to_owned(),
            );
        }
    }
    if with_gemini_auth {
        add_bind_mount(
            &mut extra_docker_args,
            &home.join(".gemini"),
            "/home/dev/.gemini",
            "Gemini auth",
            allow_missing_auth,
        )?;
    }
    if !add_bind_mount(
        &mut extra_docker_args,
        &home.join(".agents/skills"),
        "/home/dev/.agents/skills",
        "agents skills",
        true,
    )? {
        eprintln!("davy: warning: continuing without host skills mount.");
    }

    let docker_sock = if args.with_docker_sock {
        Some(resolve_docker_socket_path(args.docker_sock)?)
    } else {
        None
    };
    let docker_sock_gid = docker_sock_gid(docker_sock.as_deref())?;

    let name = args
        .name
        .unwrap_or_else(|| default_container_name(&project_dir));

    Ok(RuntimeSettings {
        project_dir,
        dockerfile,
        context_dir,
        image: args.image,
        name,
        host_uid,
        host_gid,
        keep: args.keep,
        rebuild: args.rebuild,
        no_build: args.no_build,
        docker_sock,
        docker_sock_gid,
        expose_ssh: args.expose_ssh,
        with_claude_auth,
        claude_auth_volume,
        extra_docker_args,
        extra_env_args,
        cmd: args.cmd,
    })
}

fn resolve_dockerfile(from_cli: Option<PathBuf>, local: bool) -> Result<PathBuf> {
    if let Some(path) = from_cli {
        return Ok(path);
    }

    if local {
        let cwd = env::current_dir().context("failed to read current directory")?;
        let rocky = cwd.join("rocky.Dockerfile");
        if rocky.is_file() {
            return Ok(rocky);
        }
        let debian = cwd.join("debian.Dockerfile");
        if debian.is_file() {
            return Ok(debian);
        }
        bail!(
            "no Dockerfile found in current directory (looked for {} and {})",
            rocky.display(),
            debian.display()
        );
    }

    let config_dir = home_dir()?.join(".config/davy");
    let rocky = config_dir.join("rocky.Dockerfile");
    if rocky.is_file() {
        return Ok(rocky);
    }
    let debian = config_dir.join("debian.Dockerfile");
    if debian.is_file() {
        return Ok(debian);
    }

    bail!(
        "no Dockerfile found (looked for {} and {}); use --dockerfile, --local-dockerfile, or DAVY_DOCKERFILE",
        rocky.display(),
        debian.display()
    );
}

fn default_container_name(project_dir: &Path) -> String {
    let base = project_dir
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "project".to_owned());

    let timestamp = Local::now().format("%Y%m%d-%H%M%S");
    format!("davy-{base}-{timestamp}")
}

fn maybe_build_image(settings: &RuntimeSettings) -> Result<()> {
    if settings.no_build {
        if docker_image_exists(&settings.image)? {
            return Ok(());
        }
        bail!(
            "image '{}' not found (and --no-build was set)",
            settings.image
        );
    }

    if settings.rebuild {
        return docker_build(settings, true, true);
    }

    if !docker_image_exists(&settings.image)? {
        return docker_build(settings, false, false);
    }

    Ok(())
}

fn docker_build(settings: &RuntimeSettings, pull: bool, no_cache: bool) -> Result<()> {
    let mut cmd = Command::new("docker");
    cmd.arg("build");
    if pull {
        cmd.arg("--pull");
    }
    if no_cache {
        cmd.arg("--no-cache");
    }

    cmd.arg("--build-arg")
        .arg(format!("USER_UID={}", settings.host_uid))
        .arg("--build-arg")
        .arg(format!("USER_GID={}", settings.host_gid))
        .arg("-f")
        .arg(&settings.dockerfile)
        .arg("-t")
        .arg(&settings.image)
        .arg(&settings.context_dir);

    run_checked(&mut cmd, "docker build")
}

fn docker_image_exists(image: &str) -> Result<bool> {
    let status = Command::new("docker")
        .arg("image")
        .arg("inspect")
        .arg(image)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("failed to run docker image inspect")?;

    Ok(status.success())
}

fn ensure_claude_volume_ready(settings: &RuntimeSettings) -> Result<()> {
    let mut create_volume = Command::new("docker");
    create_volume
        .arg("volume")
        .arg("create")
        .arg(&settings.claude_auth_volume);
    run_checked(&mut create_volume, "docker volume create")?;

    let mut init_volume = Command::new("docker");
    init_volume
        .arg("run")
        .arg("--rm")
        .arg("--user")
        .arg("0:0")
        .arg("-v")
        .arg(format!("{}:/auth", settings.claude_auth_volume))
        .arg(&settings.image)
        .arg("bash")
        .arg("-lc")
        .arg(format!(
            "mkdir -p /auth/.claude && touch /auth/.claude.json && chown -R {}:{} /auth",
            settings.host_uid, settings.host_gid
        ));
    run_checked(
        &mut init_volume,
        "docker run (initialize Claude auth volume)",
    )
}

fn docker_run(settings: &RuntimeSettings) -> Result<ExitStatus> {
    let mut cmd = Command::new("docker");
    cmd.arg("run").arg("-it");

    if !settings.keep {
        cmd.arg("--rm");
    }

    cmd.arg("--name")
        .arg(&settings.name)
        .arg("-v")
        .arg(format!("{}:/project", settings.project_dir.display()))
        .arg("-w")
        .arg("/project");

    if settings.with_claude_auth {
        cmd.arg("--mount").arg(format!(
            "type=volume,src={},dst=/home/dev/.claude-auth",
            settings.claude_auth_volume
        ));
    }

    if let Some(docker_sock) = settings.docker_sock.as_ref() {
        cmd.arg("-v")
            .arg(format!("{}:/var/run/docker.sock", docker_sock.display()));
        if let Some(gid) = settings.docker_sock_gid {
            cmd.arg("--group-add").arg(gid.to_string());
        }
    }

    if let Some(port) = settings.expose_ssh {
        cmd.arg("-p").arg(format!("{port}:22"));
    }

    cmd.args(&settings.extra_env_args)
        .args(&settings.extra_docker_args)
        .arg(&settings.image)
        .args(&settings.cmd);

    cmd.status().context("failed to run docker run")
}

fn wrap_bash_script(script: &str, original_cmd: Vec<OsString>) -> Vec<OsString> {
    let mut wrapped = vec![
        OsString::from("bash"),
        OsString::from("-lc"),
        OsString::from(script),
        OsString::from("--"),
    ];
    wrapped.extend(original_cmd);
    wrapped
}

fn collect_ssh_authorized_keys() -> Result<String> {
    let mut unique = HashSet::new();
    let mut keys = Vec::new();

    if let Ok(path) = env::var("DAVY_SSH_AUTHORIZED_KEYS_FILE") {
        let key_path = PathBuf::from(&path);
        if !key_path.is_file() {
            bail!("DAVY_SSH_AUTHORIZED_KEYS_FILE not found: {path}");
        }
        collect_key_lines_from_file(&key_path, &mut unique, &mut keys)?;
    } else {
        let ssh_dir = home_dir()?.join(".ssh");
        let authorized_keys = ssh_dir.join("authorized_keys");
        if authorized_keys.is_file() {
            collect_key_lines_from_file(&authorized_keys, &mut unique, &mut keys)?;
        }

        if ssh_dir.is_dir() {
            let mut pubs = fs::read_dir(&ssh_dir)
                .with_context(|| format!("failed to read {}", ssh_dir.display()))?
                .filter_map(|entry| entry.ok().map(|e| e.path()))
                .filter(|path| path.extension().is_some_and(|ext| ext == "pub"))
                .collect::<Vec<_>>();
            pubs.sort();

            for path in pubs {
                if path.is_file() {
                    collect_key_lines_from_file(&path, &mut unique, &mut keys)?;
                }
            }
        }
    }

    if keys.is_empty() {
        bail!("no SSH public keys found. Add ~/.ssh/*.pub or set DAVY_SSH_AUTHORIZED_KEYS_FILE");
    }

    Ok(format!("{}\n", keys.join("\n")))
}

fn collect_key_lines_from_file(
    path: &Path,
    unique: &mut HashSet<String>,
    output: &mut Vec<String>,
) -> Result<()> {
    let content = fs::read_to_string(path)
        .with_context(|| format!("failed to read SSH keys from {}", path.display()))?;

    for line in content
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        if unique.insert(line.to_owned()) {
            output.push(line.to_owned());
        }
    }

    Ok(())
}

fn reset_claude_auth_volume() -> Result<()> {
    let uid = get_current_uid();
    let volume = env::var("DAVY_CLAUDE_AUTH_VOLUME")
        .unwrap_or_else(|_| format!("davy-claude-auth-{uid}-v1"));

    let exists = Command::new("docker")
        .arg("volume")
        .arg("inspect")
        .arg(&volume)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("failed to run docker volume inspect")?
        .success();

    if exists {
        let mut remove_volume = Command::new("docker");
        remove_volume.arg("volume").arg("rm").arg("-f").arg(&volume);
        run_checked(&mut remove_volume, "docker volume rm")?;
        eprintln!("davy: removed Claude auth volume '{volume}'");
    } else {
        eprintln!("davy: Claude auth volume '{volume}' does not exist");
    }

    Ok(())
}

fn run_checked(cmd: &mut Command, name: &str) -> Result<()> {
    let status = cmd
        .status()
        .with_context(|| format!("failed to run {name}"))?;
    if status.success() {
        return Ok(());
    }

    match status.code() {
        Some(code) => bail!("{name} exited with status code {code}"),
        None => bail!("{name} terminated by signal"),
    }
}

fn home_dir() -> Result<PathBuf> {
    if let Some(home) = env::var_os("HOME") {
        return Ok(PathBuf::from(home));
    }

    #[cfg(unix)]
    {
        return get_user_by_uid(get_current_uid())
            .map(|user| user.home_dir().to_path_buf())
            .context("HOME is not set and current user home directory could not be resolved");
    }

    #[cfg(not(unix))]
    {
        bail!("HOME is not set");
    }
}

fn add_bind_mount(
    args: &mut Vec<OsString>,
    source: &Path,
    target: &str,
    label: &str,
    allow_missing: bool,
) -> Result<bool> {
    if source.is_dir() {
        push_volume(args, format!("{}:{target}", source.display()));
        return Ok(true);
    }

    if source.exists() {
        bail!(
            "{label} mount source is not a directory: {}",
            source.display()
        );
    }

    if allow_missing {
        eprintln!(
            "davy: warning: {label} mount source not found at {}; skipping.",
            source.display()
        );
        return Ok(false);
    }

    bail!("{label} mount source not found: {}", source.display());
}

fn resolve_docker_socket_path(from_cli: Option<PathBuf>) -> Result<PathBuf> {
    let socket = if let Some(path) = from_cli {
        path
    } else if let Some(path) = env::var("DOCKER_HOST")
        .ok()
        .as_deref()
        .and_then(parse_unix_socket_from_docker_host)
    {
        path
    } else if let Ok(host) = env::var("DOCKER_HOST") {
        bail!(
            "DOCKER_HOST is set to '{host}', but --docker needs a local unix socket. Set --docker-sock or DAVY_DOCKER_SOCK."
        );
    } else {
        PathBuf::from("/var/run/docker.sock")
    };

    let metadata = fs::metadata(&socket)
        .with_context(|| format!("docker socket not found: {}", socket.display()))?;
    #[cfg(unix)]
    {
        if !metadata.file_type().is_socket() {
            bail!(
                "docker socket path is not a unix socket: {}",
                socket.display()
            );
        }
    }
    #[cfg(not(unix))]
    {
        let _ = metadata;
    }

    Ok(socket)
}

fn parse_unix_socket_from_docker_host(docker_host: &str) -> Option<PathBuf> {
    docker_host
        .strip_prefix("unix://")
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
}

fn docker_sock_gid(path: Option<&Path>) -> Result<Option<u32>> {
    let Some(path) = path else {
        return Ok(None);
    };

    #[cfg(unix)]
    {
        let metadata = fs::metadata(path).with_context(|| {
            format!(
                "failed to read metadata for docker socket at {}",
                path.display()
            )
        })?;
        Ok(Some(metadata.gid()))
    }

    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(None)
    }
}

fn push_env(args: &mut Vec<OsString>, value: impl Into<OsString>) {
    args.push(OsString::from("-e"));
    args.push(value.into());
}

fn push_volume(args: &mut Vec<OsString>, volume: impl Into<OsString>) {
    args.push(OsString::from("-v"));
    args.push(volume.into());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_name_has_prefix() {
        let name = default_container_name(Path::new("/tmp/my-project"));
        assert!(name.starts_with("davy-my-project-"));
        assert_eq!(name.len(), "davy-my-project-YYYYMMDD-HHMMSS".len());
    }

    #[test]
    fn wrap_script_prefixes_command() {
        let wrapped = wrap_bash_script("echo hi", vec![OsString::from("bash")]);
        let expected = vec![
            OsString::from("bash"),
            OsString::from("-lc"),
            OsString::from("echo hi"),
            OsString::from("--"),
            OsString::from("bash"),
        ];
        assert_eq!(wrapped, expected);
    }

    #[test]
    fn clap_parses_extra_docker_args_and_command() {
        let cli = Cli::try_parse_from([
            "davy",
            "--name",
            "my-name",
            "--privileged",
            "--",
            "echo",
            "ok",
        ])
        .expect("CLI should parse");

        assert_eq!(cli.run.name.as_deref(), Some("my-name"));
        assert_eq!(
            cli.run.extra_docker_args,
            vec![OsString::from("--privileged")]
        );
        assert_eq!(
            cli.run.cmd,
            vec![OsString::from("echo"), OsString::from("ok")]
        );
    }

    #[test]
    fn clap_expose_ssh_defaults_to_222() {
        let cli = Cli::try_parse_from(["davy", "--expose-ssh"]).expect("CLI should parse");
        assert_eq!(cli.run.expose_ssh, Some(222));
    }

    #[test]
    fn clap_parses_passthrough_docker_args_without_command() {
        let cli = Cli::try_parse_from(["davy", "--privileged", "--network", "host"])
            .expect("CLI should parse");
        assert_eq!(
            cli.run.extra_docker_args,
            vec![
                OsString::from("--privileged"),
                OsString::from("--network"),
                OsString::from("host")
            ]
        );
        assert!(cli.run.cmd.is_empty());
    }

    #[test]
    fn clap_parses_auth_claude_reset_subcommand() {
        let cli =
            Cli::try_parse_from(["davy", "auth", "claude", "reset"]).expect("CLI should parse");

        assert!(matches!(
            cli.command,
            Some(Commands::Auth {
                command: AuthCommands::Claude {
                    command: ClaudeCommands::Reset
                }
            })
        ));
    }

    #[test]
    fn clap_parses_docker_sock_path() {
        let cli = Cli::try_parse_from(["davy", "--docker", "--docker-sock", "/tmp/docker.sock"])
            .expect("CLI should parse");
        assert!(cli.run.with_docker_sock);
        assert_eq!(cli.run.docker_sock, Some(PathBuf::from("/tmp/docker.sock")));
    }

    #[test]
    fn parse_unix_docker_host_extracts_socket_path() {
        let socket = parse_unix_socket_from_docker_host("unix:///run/user/1000/docker.sock");
        assert_eq!(socket, Some(PathBuf::from("/run/user/1000/docker.sock")));
    }

    #[test]
    fn parse_non_unix_docker_host_returns_none() {
        assert_eq!(
            parse_unix_socket_from_docker_host("tcp://127.0.0.1:2375"),
            None
        );
    }

    #[test]
    fn clap_parses_local_dockerfile_flag() {
        let cli = Cli::try_parse_from(["davy", "--local-dockerfile"]).expect("CLI should parse");
        assert!(cli.run.local_dockerfile);
    }
}
