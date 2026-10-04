mock_provider "aws" {}

variables {
  aws_region        = "test-region-1"
  state_bucket_name = "test-pulso-tfstate"
  github_org        = "example-org"
  github_repo       = "example-infra"
}

run "oidc_provider_trusts_only_the_github_audience" {
  command = apply

  assert {
    condition     = aws_iam_openid_connect_provider.github[0].url == "https://token.actions.githubusercontent.com" && contains(aws_iam_openid_connect_provider.github[0].client_id_list, "sts.amazonaws.com")
    error_message = "OIDC provider must be GitHub with the sts audience."
  }
}

run "deploy_role_trust_is_pinned_to_org_repo_and_ref" {
  command = apply

  assert {
    condition     = strcontains(aws_iam_role.deploy[0].assume_role_policy, "repo:example-org/example-infra:ref:refs/heads/main")
    error_message = "Trust must name the exact org/repo/branch."
  }

  assert {
    condition     = !strcontains(aws_iam_role.deploy[0].assume_role_policy, "repo:example-org/*")
    error_message = "No wildcard repo in the trust policy."
  }
}

run "deploy_role_state_access_is_scoped_to_the_state_bucket_only" {
  command = apply

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.state[0].policy).Statement) == 2 && !strcontains(aws_iam_role_policy.state[0].policy, "\"Resource\":\"*\"") && !strcontains(aws_iam_role_policy.state[0].policy, "\"Action\":\"*\"")
    error_message = "State policy has two statements on the state bucket arn only, never all actions or all resources."
  }
}

run "github_org_and_repo_must_be_given_together" {
  command = plan

  variables {
    github_org  = "example-org"
    github_repo = ""
  }

  expect_failures = [var.github_org]
}

run "ecr_has_the_engine_repository_only_by_default" {
  command = apply

  assert {
    condition     = toset(keys(module.ecr)) == toset(["pulso-engine", "core-runtime", "llm-gateway", "support-platform-api", "support-platform-web", "caddy"])
    error_message = "Default repositories are exactly the images the hackathon compose bundles pull (console is not needed; caddy is a digest-pinned mirror)."
  }
}

run "ecr_names_are_prefixable" {
  command = apply

  variables {
    ecr_repository_prefix = "newacct"
  }

  assert {
    condition     = output.ecr_repository_names["pulso-engine"] == "newacct/pulso-engine"
    error_message = "Repository name = prefix/name, matching the <env>/pulso-engine convention."
  }
}

run "no_github_variables_means_no_oidc" {
  command = apply

  variables {
    github_org  = ""
    github_repo = ""
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0 && length(aws_iam_role.deploy) == 0
    error_message = "OIDC is only declared when org and repo are provided."
  }
}
