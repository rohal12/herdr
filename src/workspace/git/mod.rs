mod config;
#[cfg(test)]
mod config_tests;
mod discovery;
mod status;
#[cfg(test)]
mod test_support;

pub use self::{
    discovery::{
        derive_label_from_cwd, effective_git_status_cwd, git_branch, git_space_metadata,
        resolve_activity_worktree, GitSpaceMetadata,
    },
    status::{git_status_cache_key, git_status_snapshot_for_cwd, GitStatusCacheEntry},
};

#[cfg(test)]
pub(super) use self::status::git_ahead_behind;
