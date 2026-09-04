# Billing budget alert.
#
# The ~$20-25/month ceiling is a hard requirement of this project, but nothing
# enforced or even observed it: Cloud Run scales to zero, so a runaway cost is
# far more likely to come from a configuration change (dss_min_instances >= 1,
# enable_load_balancer, a Cloud SQL tier bump) than from traffic. Those show up
# on the invoice a month later unless something watches.
#
# A budget only notifies — it never caps spend and never stops a service.
#
# Off unless var.billing_account_id is set, because creating a budget needs a
# role on the *billing account* (roles/billing.costsManager), which is separate
# from project ownership. Find the ID with:
#
#   gcloud billing projects describe <project_id> --format='value(billingAccountName)'

locals {
  budget_enabled = var.billing_account_id != ""
}

# Nothing here is billable, so this is a warning rather than a precondition —
# and there is no resource to hang a precondition on when the budget is off.
# It exists because the failure is silent: you configure the addresses that
# should be warned when spend runs away, and no budget is ever created.
check "budget_emails_need_billing_account" {
  assert {
    condition     = length(var.budget_alert_emails) == 0 || local.budget_enabled
    error_message = "budget_alert_emails is set but billing_account_id is empty, so no budget and no notification channels are created and nobody will be alerted. Set billing_account_id or clear the addresses."
  }
}

resource "google_monitoring_notification_channel" "budget_email" {
  for_each = local.budget_enabled ? toset(var.budget_alert_emails) : toset([])

  display_name = "Trustex budget alert (${each.value})"
  type         = "email"

  labels = {
    email_address = each.value
  }

  depends_on = [time_sleep.api_propagation]
}

resource "google_billing_budget" "main" {
  count = local.budget_enabled ? 1 : 0

  billing_account = var.billing_account_id
  display_name    = "${local.name_prefix} monthly budget"

  # Scoped to this project only, so a shared billing account is not measured.
  budget_filter {
    projects               = ["projects/${var.project_id}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = var.budget_currency
      units         = tostring(var.budget_amount)
    }
  }

  # 50% and 80% are the useful ones: they arrive while there is still time to
  # undo whatever caused it. 100% is the record that the ceiling was crossed,
  # and the forecast rule catches a trend that has not yet spent the money.
  threshold_rules {
    threshold_percent = 0.5
  }

  threshold_rules {
    threshold_percent = 0.8
  }

  threshold_rules {
    threshold_percent = 1.0
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  # With no monitoring channels, Cloud Billing still emails the billing account
  # admins and project owners — the default, and enough for a small project.
  dynamic "all_updates_rule" {
    for_each = length(var.budget_alert_emails) > 0 ? [1] : []
    content {
      monitoring_notification_channels = [
        for c in google_monitoring_notification_channel.budget_email : c.id
      ]
      disable_default_iam_recipients = false
    }
  }

  depends_on = [time_sleep.api_propagation]
}
