###############################################################################
# AMI - Amazon Linux 2023 mais recente (x86_64)
###############################################################################

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

###############################################################################
# Key pair (acesso SSH via WARP)
###############################################################################

resource "aws_key_pair" "this" {
  key_name   = "${local.name}-key"
  public_key = var.ssh_public_key
}

###############################################################################
# IAM role da instancia
# - Acesso ao bucket S3 do Dify (storage de arquivos via IAM, sem chaves)
# - SSM core como acesso admin de backup (outbound-only, sem abrir portas)
###############################################################################

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

###############################################################################
# Acesso da instancia ao parametro SMTP (senha do SES) no Parameter Store
# - Lido pelo app/deploy.sh (via instance role) e injetado no .env do Dify.
# - SecureString com a chave gerenciada aws/ssm; o kms:Decrypt e' restringido
#   a chamadas feitas via SSM (kms:ViaService), nunca uso direto da chave.
# - A senha NUNCA trafega pelo SSM Run Command: a instancia a le daqui.
###############################################################################

data "aws_iam_policy_document" "smtp_param" {
  statement {
    sid       = "ReadSmtpPassword"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${local.name}/smtp_password"]
  }

  statement {
    sid       = "DecryptViaSsm"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "smtp_param" {
  name   = "${local.name}-smtp-param"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.smtp_param.json
}

###############################################################################
# Launch template (Amazon Linux + Docker + cloudflared via container)
###############################################################################

resource "aws_launch_template" "dify" {
  name_prefix   = "${local.name}-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.this.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.instance.name
  }

  vpc_security_group_ids = [aws_security_group.instance.id]

  # Token do tunnel (gerado pela Cloudflare) injetado no user-data.
  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    tunnel_token = data.cloudflare_zero_trust_tunnel_cloudflared_token.this.token
  }))

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # IMDSv2 obrigatorio
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = local.name })
  }
}

###############################################################################
# Instancia EC2
###############################################################################

resource "aws_instance" "dify" {
  subnet_id = aws_subnet.public.id

  launch_template {
    id      = aws_launch_template.dify.id
    version = "$Latest"
  }

  tags = {
    Name = local.name
  }
}

###############################################################################
# Volume de dados PERSISTENTE (montado em /opt/dify pelo user_data)
# - Guarda o repo do Dify, o .env (SECRET_KEY) e os volumes dos bancos
#   (Postgres/Redis/Weaviate). O EBS root e' descartavel; este NAO.
# - Sobrevive a recriacao/replace da instancia: o Terraform desanexa do antigo
#   e reanexa no novo; os dados continuam intactos.
# - prevent_destroy: protege contra 'tofu destroy'/replace acidental do volume.
#   (Para destruir de proposito, remova o flag ou apague o volume na mao.)
###############################################################################

resource "aws_ebs_volume" "data" {
  availability_zone = aws_subnet.public.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${local.name}-data"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.dify.id

  # Para a instancia antes de desanexar (desmonta limpo em um replace).
  stop_instance_before_detaching = true
}
