# =============================================================================
# Discord control + idle auto-stop
#
# One Lambda does both jobs:
#   - Discord slash commands (/valheim start|stop|status) arrive at its
#     function URL, Ed25519-signed by Discord. Signature verification IS the
#     authentication; the URL itself needs no auth.
#   - Every 5 minutes EventBridge invokes it with {"source":"valheim.idle-check"}.
#     It asks the game for its player count (Steam A2S query on UDP 2457) and
#     stops the instance once that's been zero for idle_minutes.
# Code: discord/lambda/handler.py. PyNaCl (for signature checks) is a Lambda
# layer built by discord/layer/build-layer.sh (run it once before the first plan).
# =============================================================================

data "archive_file" "control_lambda" {
  type        = "zip"
  source_file = "${path.module}/discord/lambda/handler.py"
  output_path = "${path.module}/.terraform/valheim-control.zip"
}

resource "aws_lambda_layer_version" "pynacl" {
  layer_name          = "valheim-pynacl"
  filename            = "${path.module}/discord/layer/pynacl-layer.zip"
  source_code_hash    = filebase64sha256("${path.module}/discord/layer/pynacl-layer.zip")
  compatible_runtimes = ["python3.12"]
  description         = "PyNaCl for Discord Ed25519 signature verification"
}

resource "aws_iam_role" "control_lambda" {
  name = "valheim-control-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Start/stop/tag exactly one instance. DescribeInstances can't be
# resource-scoped, so it's the one "*" here; it's read-only.
resource "aws_iam_role_policy" "control_lambda" {
  name = "valheim-control"
  role = aws_iam_role.control_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances", "ec2:CreateTags", "ec2:DeleteTags"]
        Resource = aws_instance.valheim.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.control_lambda.arn}:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "control_lambda" {
  name              = "/aws/lambda/valheim-control"
  retention_in_days = 14
}

resource "aws_lambda_function" "control" {
  function_name    = "valheim-control"
  role             = aws_iam_role.control_lambda.arn
  runtime          = "python3.12"
  architectures    = ["x86_64"]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.control_lambda.output_path
  source_code_hash = data.archive_file.control_lambda.output_base64sha256
  layers           = [aws_lambda_layer_version.pynacl.arn]
  timeout          = 10
  memory_size      = 256

  # No reserved_concurrent_executions here: AWS won't let a function reserve
  # capacity if it would leave the account with fewer than 10 unreserved, and
  # a new account's total limit IS 10. That account-wide limit already bounds
  # what junk traffic to the public URL can cost.

  environment {
    variables = {
      DISCORD_PUBLIC_KEY = var.discord_public_key
      DISCORD_GUILD_ID   = var.discord_guild_id
      INSTANCE_ID        = aws_instance.valheim.id
      SERVER_IP          = aws_eip.valheim.public_ip
      GAME_PORT          = "2456"
      IDLE_MINUTES       = tostring(var.idle_minutes)
    }
  }

  depends_on = [aws_cloudwatch_log_group.control_lambda]
}

# Public HTTPS endpoint Discord posts interactions to. Auth is NONE at the URL
# level because Discord can't sign AWS requests; the handler rejects anything
# without a valid Discord signature.
resource "aws_lambda_function_url" "control" {
  function_name      = aws_lambda_function.control.function_name
  authorization_type = "NONE"
}

# authorization_type = "NONE" is not enough on its own. Lambda only serves a
# public function URL when the function's resource policy grants BOTH
# lambda:InvokeFunctionUrl AND lambda:InvokeFunction to principal "*" (the
# console says so in a banner on the Function URL page). Missing either one
# gives a 403 from the URL before the handler runs.
resource "aws_lambda_permission" "public_url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.control.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# The FunctionUrlAuthType condition is only valid on InvokeFunctionUrl, so this
# grant is unconditional. In practice that means any AWS principal who learns
# the function ARN could invoke it directly with an arbitrary event. Bounded:
# the Discord path rejects anything Discord didn't sign, and the only other
# path is the idle check, which can at most stop the server after it has
# already been empty for idle_minutes.
resource "aws_lambda_permission" "public_invoke" {
  statement_id  = "AllowPublicInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.control.function_name
  principal     = "*"
}

# If the URL STILL returns 403 with both statements present, the account has
# Lambda's newer per-function public-access block turned on; it shows up in
# the console under Configuration > Permissions > "Block public access" and
# has to be unchecked there (it persists across applies).

# --- Idle check every 5 minutes ---
resource "aws_cloudwatch_event_rule" "idle_check" {
  name                = "valheim-idle-check"
  description         = "Stop the Valheim instance once it has had no players for a while"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "idle_check" {
  rule  = aws_cloudwatch_event_rule.idle_check.name
  arn   = aws_lambda_function.control.arn
  input = jsonencode({ source = "valheim.idle-check" })
}

resource "aws_lambda_permission" "idle_check" {
  statement_id  = "AllowEventBridgeIdleCheck"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.control.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.idle_check.arn
}
