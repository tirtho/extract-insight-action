const path = require('path');
const pptxgen = require('pptxgenjs');

const root = path.resolve(__dirname, '..', '..');
const iconDir = path.join(root, 'artifacts', 'ppt-icons');

const icons = {
  appService: path.join(iconDir, '10035-icon-service-App-Services.svg'),
  serviceBus: path.join(iconDir, '10836-icon-service-Service-Bus.svg'),
  cosmos: path.join(iconDir, '10121-icon-service-Azure-Cosmos-DB.svg'),
  keyVault: path.join(iconDir, '10245-icon-service-Key-Vaults.svg'),
  storage: path.join(iconDir, '10086-icon-service-Storage-Accounts.svg'),
  managedIdentity: path.join(iconDir, '10227-icon-service-Managed-Identities.svg'),
  entra: path.join(iconDir, '10222-icon-service-Azure-AD-Domain-Services.svg'),
  cognitive: path.join(iconDir, '10162-icon-service-Cognitive-Services.svg')
};

const outFile = path.join(root, 'Extract-Insight-Action-Architecture-Enterprise.pptx');

const pptx = new pptxgen();
pptx.layout = 'LAYOUT_WIDE';
pptx.author = 'GitHub Copilot';
pptx.company = 'Microsoft';
pptx.subject = 'Extract Insight Action architecture';
pptx.title = 'Extract-Insight-Action Enterprise Architecture';
pptx.theme = {
  headFontFace: 'Segoe UI Semibold',
  bodyFontFace: 'Segoe UI',
  lang: 'en-US'
};

const slide = pptx.addSlide();

slide.background = { color: 'F4F7FB' };
slide.addShape(pptx.ShapeType.rect, {
  x: 0,
  y: 0,
  w: 13.33,
  h: 0.95,
  fill: { color: '0F3A5B' },
  line: { color: '0F3A5B' }
});

slide.addText('Extract-Insight-Action | Enterprise Azure Reference Architecture', {
  x: 0.45,
  y: 0.2,
  w: 10.6,
  h: 0.4,
  fontFace: 'Segoe UI Semibold',
  fontSize: 17,
  color: 'FFFFFF',
  margin: 0
});

slide.addText('Production topology with identity, messaging, AI enrichment, and review workflows', {
  x: 0.45,
  y: 0.56,
  w: 9.8,
  h: 0.25,
  fontFace: 'Segoe UI',
  fontSize: 10,
  color: 'D9E6F2',
  margin: 0
});

function zone(x, y, w, h, title) {
  slide.addShape(pptx.ShapeType.roundRect, {
    x,
    y,
    w,
    h,
    rectRadius: 0.08,
    fill: { color: 'FFFFFF' },
    line: { color: 'C8D8E8', width: 1 }
  });
  slide.addText(title, {
    x: x + 0.2,
    y: y + 0.06,
    w: w - 0.4,
    h: 0.22,
    fontFace: 'Segoe UI Semibold',
    fontSize: 10,
    color: '2B4D69',
    margin: 0
  });
}

function node({ x, y, w, h, label, icon, subtitle }) {
  slide.addShape(pptx.ShapeType.roundRect, {
    x,
    y,
    w,
    h,
    rectRadius: 0.06,
    fill: { color: 'F9FCFF' },
    line: { color: 'BFD3E6', width: 1 }
  });
  if (icon) {
    slide.addImage({ path: icon, x: x + 0.08, y: y + 0.09, w: 0.3, h: 0.3 });
  }
  slide.addText(label, {
    x: x + 0.43,
    y: y + 0.08,
    w: w - 0.48,
    h: 0.2,
    fontFace: 'Segoe UI Semibold',
    fontSize: 8.8,
    color: '16324A',
    margin: 0
  });
  if (subtitle) {
    slide.addText(subtitle, {
      x: x + 0.43,
      y: y + 0.28,
      w: w - 0.5,
      h: h - 0.3,
      fontFace: 'Segoe UI',
      fontSize: 7,
      color: '4D657A',
      margin: 0,
      valign: 'top'
    });
  }
}

function connector(x, y, w, h, dashed = false) {
  slide.addShape(pptx.ShapeType.chevron, {
    x,
    y,
    w,
    h,
    fill: { color: '5A86AF' },
    line: { color: '5A86AF', width: 0.5, dashType: dashed ? 'dash' : 'solid' }
  });
}

zone(0.35, 1.2, 3.0, 3.95, 'Ingestion & Extraction');
zone(3.65, 1.2, 5.15, 3.95, 'Insight Processing & State');
zone(9.05, 1.2, 3.95, 3.95, 'Experience & Action');
zone(0.35, 5.25, 12.65, 1.95, 'Identity, Secrets, and Platform Controls');

node({
  x: 0.58,
  y: 1.62,
  w: 2.5,
  h: 0.75,
  label: 'Mailbox to Queue Function',
  icon: icons.appService,
  subtitle: 'Pulls messages and attachments'
});
node({
  x: 0.58,
  y: 2.57,
  w: 2.5,
  h: 0.75,
  label: 'Queue Orchestration Function',
  icon: icons.appService,
  subtitle: 'Coordinates extraction pipeline'
});
node({
  x: 0.58,
  y: 3.52,
  w: 2.5,
  h: 0.75,
  label: 'CU Queue to DB Function',
  icon: icons.appService,
  subtitle: 'Persists CU analysis output'
});

node({
  x: 3.95,
  y: 1.62,
  w: 2.35,
  h: 0.75,
  label: 'Azure Service Bus',
  icon: icons.serviceBus,
  subtitle: 'Decoupled event transport'
});
node({
  x: 3.95,
  y: 2.57,
  w: 2.35,
  h: 0.75,
  label: 'Azure Cosmos DB',
  icon: icons.cosmos,
  subtitle: 'Email + insight data store'
});
node({
  x: 3.95,
  y: 3.52,
  w: 2.35,
  h: 0.75,
  label: 'Azure Storage',
  icon: icons.storage,
  subtitle: 'Raw content and artifacts'
});

node({
  x: 6.38,
  y: 2.1,
  w: 2.15,
  h: 0.95,
  label: 'Content Understanding',
  icon: icons.cognitive,
  subtitle: 'Document, image, audio, video schemas'
});
node({
  x: 6.38,
  y: 3.25,
  w: 2.15,
  h: 0.95,
  label: 'AI Enrichment',
  icon: icons.cognitive,
  subtitle: 'Classification and action suggestions'
});

node({
  x: 9.35,
  y: 1.7,
  w: 3.35,
  h: 0.95,
  label: 'Insight UI (Spring Boot)',
  icon: icons.appService,
  subtitle: 'Operational dashboard and profile controls'
});
node({
  x: 9.35,
  y: 2.9,
  w: 3.35,
  h: 0.95,
  label: 'Email Reviewer Agent',
  icon: icons.appService,
  subtitle: 'Assisted decisions and recommendations'
});
node({
  x: 9.35,
  y: 4.1,
  w: 3.35,
  h: 0.8,
  label: 'Action Execution Layer',
  icon: icons.serviceBus,
  subtitle: 'Triggers downstream process workflows'
});

node({
  x: 0.7,
  y: 5.65,
  w: 2.8,
  h: 1.2,
  label: 'Microsoft Entra ID',
  icon: icons.entra,
  subtitle: 'OIDC login, role claims, Graph delegated auth'
});
node({
  x: 3.75,
  y: 5.65,
  w: 2.8,
  h: 1.2,
  label: 'Managed Identities',
  icon: icons.managedIdentity,
  subtitle: 'Workload identities for service-to-service access'
});
node({
  x: 6.8,
  y: 5.65,
  w: 2.8,
  h: 1.2,
  label: 'Azure Key Vault',
  icon: icons.keyVault,
  subtitle: 'Secrets, certificates, and rotation controls'
});

slide.addShape(pptx.ShapeType.roundRect, {
  x: 9.9,
  y: 5.65,
  w: 2.75,
  h: 1.2,
  rectRadius: 0.06,
  fill: { color: 'EAF3FB' },
  line: { color: 'BFD3E6', width: 1 }
});
slide.addText('Governance', {
  x: 10.02,
  y: 5.75,
  w: 2.5,
  h: 0.2,
  fontFace: 'Segoe UI Semibold',
  fontSize: 8.8,
  color: '16324A',
  margin: 0
});
slide.addText('Least privilege\nCustom role: EIAUserProfileEditor\nOperational scripts and runbooks', {
  x: 10.02,
  y: 5.97,
  w: 2.5,
  h: 0.78,
  fontFace: 'Segoe UI',
  fontSize: 7,
  color: '4D657A',
  margin: 0,
  valign: 'top'
});

connector(3.2, 1.9, 0.35, 0.12);
connector(3.2, 2.85, 0.35, 0.12);
connector(3.2, 3.8, 0.35, 0.12);

connector(6.15, 2.2, 0.18, 0.1);
connector(6.15, 3.4, 0.18, 0.1);

connector(8.72, 2.46, 0.28, 0.12);
connector(8.72, 3.58, 0.28, 0.12);

slide.addShape(pptx.ShapeType.line, {
  x: 10.9,
  y: 4.95,
  w: 0,
  h: 0.62,
  line: { color: '5A86AF', width: 1.2, beginArrowType: 'none', endArrowType: 'triangle' }
});
slide.addShape(pptx.ShapeType.line, {
  x: 1.9,
  y: 4.9,
  w: 0,
  h: 0.35,
  line: { color: '5A86AF', width: 1.1, beginArrowType: 'triangle', endArrowType: 'none' }
});
slide.addShape(pptx.ShapeType.line, {
  x: 5.1,
  y: 3.4,
  w: 0,
  h: 1.85,
  line: { color: '5A86AF', width: 1.1, beginArrowType: 'triangle', endArrowType: 'none' }
});
slide.addShape(pptx.ShapeType.line, {
  x: 8.2,
  y: 3.75,
  w: 0,
  h: 1.5,
  line: { color: '5A86AF', width: 1.1, beginArrowType: 'triangle', endArrowType: 'none' }
});

slide.addText('Enterprise boundary: Azure Subscription and Resource Group deployment model', {
  x: 0.45,
  y: 7.18,
  w: 7.2,
  h: 0.2,
  fontFace: 'Segoe UI',
  fontSize: 7,
  color: '6A8093',
  margin: 0
});

const targetSlide = pptx.addSlide();

targetSlide.background = { color: 'F4F7FB' };
targetSlide.addShape(pptx.ShapeType.rect, {
  x: 0,
  y: 0,
  w: 13.33,
  h: 0.95,
  fill: { color: '0F3A5B' },
  line: { color: '0F3A5B' }
});

targetSlide.addText('Extract-Insight-Action | Target Architecture', {
  x: 0.45,
  y: 0.2,
  w: 8.6,
  h: 0.4,
  fontFace: 'Segoe UI Semibold',
  fontSize: 17,
  color: 'FFFFFF',
  margin: 0
});

targetSlide.addText('Future-state platform with hardened security, observability, and scalable AI operations', {
  x: 0.45,
  y: 0.56,
  w: 10.5,
  h: 0.25,
  fontFace: 'Segoe UI',
  fontSize: 10,
  color: 'D9E6F2',
  margin: 0
});

function tzone(x, y, w, h, title) {
  targetSlide.addShape(pptx.ShapeType.roundRect, {
    x,
    y,
    w,
    h,
    rectRadius: 0.08,
    fill: { color: 'FFFFFF' },
    line: { color: 'C8D8E8', width: 1 }
  });
  targetSlide.addText(title, {
    x: x + 0.2,
    y: y + 0.06,
    w: w - 0.4,
    h: 0.22,
    fontFace: 'Segoe UI Semibold',
    fontSize: 10,
    color: '2B4D69',
    margin: 0
  });
}

function tnode({ x, y, w, h, label, icon, subtitle }) {
  targetSlide.addShape(pptx.ShapeType.roundRect, {
    x,
    y,
    w,
    h,
    rectRadius: 0.06,
    fill: { color: 'F9FCFF' },
    line: { color: 'BFD3E6', width: 1 }
  });
  if (icon) {
    targetSlide.addImage({ path: icon, x: x + 0.08, y: y + 0.09, w: 0.3, h: 0.3 });
  }
  targetSlide.addText(label, {
    x: x + 0.43,
    y: y + 0.08,
    w: w - 0.48,
    h: 0.2,
    fontFace: 'Segoe UI Semibold',
    fontSize: 8.8,
    color: '16324A',
    margin: 0
  });
  if (subtitle) {
    targetSlide.addText(subtitle, {
      x: x + 0.43,
      y: y + 0.28,
      w: w - 0.5,
      h: h - 0.3,
      fontFace: 'Segoe UI',
      fontSize: 7,
      color: '4D657A',
      margin: 0,
      valign: 'top'
    });
  }
}

function tconnector(x, y, w, h) {
  targetSlide.addShape(pptx.ShapeType.chevron, {
    x,
    y,
    w,
    h,
    fill: { color: '5A86AF' },
    line: { color: '5A86AF', width: 0.5 }
  });
}

tzone(0.35, 1.2, 3.05, 3.95, 'Event Intake & Orchestration');
tzone(3.7, 1.2, 5.0, 3.95, 'AI Insight Fabric');
tzone(8.95, 1.2, 4.05, 3.95, 'Experience, Governance, and Actions');
tzone(0.35, 5.25, 12.65, 1.95, 'Security, Access, and Runtime Platform');

tnode({
  x: 0.58,
  y: 1.62,
  w: 2.55,
  h: 0.75,
  label: 'Event Intake Functions',
  icon: icons.appService,
  subtitle: 'Mailbox, file, and webhook channels'
});
tnode({
  x: 0.58,
  y: 2.57,
  w: 2.55,
  h: 0.75,
  label: 'Service Bus Topics',
  icon: icons.serviceBus,
  subtitle: 'Scalable fan-out for parallel processing'
});
tnode({
  x: 0.58,
  y: 3.52,
  w: 2.55,
  h: 0.75,
  label: 'Durable Orchestrator',
  icon: icons.appService,
  subtitle: 'Retry, compensation, and SLA-aware flows'
});

tnode({
  x: 3.95,
  y: 1.62,
  w: 2.2,
  h: 0.75,
  label: 'Content Understanding',
  icon: icons.cognitive,
  subtitle: 'Structured extraction by schema'
});
tnode({
  x: 3.95,
  y: 2.57,
  w: 2.2,
  h: 0.75,
  label: 'AI Enrichment Services',
  icon: icons.cognitive,
  subtitle: 'Summaries, sentiment, action candidates'
});
tnode({
  x: 3.95,
  y: 3.52,
  w: 2.2,
  h: 0.75,
  label: 'Policy and Prompt Registry',
  icon: icons.storage,
  subtitle: 'Versioned prompts and quality controls'
});

tnode({
  x: 6.28,
  y: 1.62,
  w: 2.2,
  h: 0.75,
  label: 'Cosmos DB (Operational)',
  icon: icons.cosmos,
  subtitle: 'Case state, indexing, and outcomes'
});
tnode({
  x: 6.28,
  y: 2.57,
  w: 2.2,
  h: 0.75,
  label: 'Storage Data Lake',
  icon: icons.storage,
  subtitle: 'Immutable content and audit artifacts'
});
tnode({
  x: 6.28,
  y: 3.52,
  w: 2.2,
  h: 0.75,
  label: 'Observability Stream',
  icon: icons.serviceBus,
  subtitle: 'Pipeline metrics, traces, and alerts'
});

tnode({
  x: 9.25,
  y: 1.62,
  w: 3.45,
  h: 0.75,
  label: 'Insight Portal and APIs',
  icon: icons.appService,
  subtitle: 'Analyst workflows and decision cockpit'
});
tnode({
  x: 9.25,
  y: 2.57,
  w: 3.45,
  h: 0.75,
  label: 'Action Automation Plane',
  icon: icons.serviceBus,
  subtitle: 'Rule-based and agent-assisted execution'
});
tnode({
  x: 9.25,
  y: 3.52,
  w: 3.45,
  h: 0.75,
  label: 'Human-in-the-Loop Controls',
  icon: icons.appService,
  subtitle: 'Approval queues, exceptions, and override logs'
});

tnode({
  x: 0.7,
  y: 5.65,
  w: 2.85,
  h: 1.2,
  label: 'Microsoft Entra ID',
  icon: icons.entra,
  subtitle: 'Conditional access, role claims, delegated Graph'
});
tnode({
  x: 3.8,
  y: 5.65,
  w: 2.85,
  h: 1.2,
  label: 'Managed Identity and Key Vault',
  icon: icons.keyVault,
  subtitle: 'Secretless auth and certificate lifecycle'
});
tnode({
  x: 6.9,
  y: 5.65,
  w: 2.85,
  h: 1.2,
  label: 'Platform Guardrails',
  icon: icons.managedIdentity,
  subtitle: 'Least privilege, policy as code, drift checks'
});

targetSlide.addShape(pptx.ShapeType.roundRect, {
  x: 10.0,
  y: 5.65,
  w: 2.65,
  h: 1.2,
  rectRadius: 0.06,
  fill: { color: 'EAF3FB' },
  line: { color: 'BFD3E6', width: 1 }
});
targetSlide.addText('Target KPIs', {
  x: 10.12,
  y: 5.75,
  w: 2.4,
  h: 0.2,
  fontFace: 'Segoe UI Semibold',
  fontSize: 8.8,
  color: '16324A',
  margin: 0
});
targetSlide.addText('Faster triage\nHigher action quality\nTraceable governance by design', {
  x: 10.12,
  y: 5.97,
  w: 2.35,
  h: 0.78,
  fontFace: 'Segoe UI',
  fontSize: 7,
  color: '4D657A',
  margin: 0,
  valign: 'top'
});

tconnector(3.25, 1.9, 0.35, 0.12);
tconnector(3.25, 2.85, 0.35, 0.12);
tconnector(3.25, 3.8, 0.35, 0.12);

tconnector(6.17, 1.9, 0.08, 0.12);
tconnector(6.17, 2.85, 0.08, 0.12);
tconnector(6.17, 3.8, 0.08, 0.12);

tconnector(8.72, 1.9, 0.2, 0.12);
tconnector(8.72, 2.85, 0.2, 0.12);
tconnector(8.72, 3.8, 0.2, 0.12);

targetSlide.addShape(pptx.ShapeType.line, {
  x: 1.95,
  y: 4.9,
  w: 0,
  h: 0.35,
  line: { color: '5A86AF', width: 1.1, beginArrowType: 'triangle', endArrowType: 'none' }
});
targetSlide.addShape(pptx.ShapeType.line, {
  x: 5.25,
  y: 3.5,
  w: 0,
  h: 1.75,
  line: { color: '5A86AF', width: 1.1, beginArrowType: 'triangle', endArrowType: 'none' }
});
targetSlide.addShape(pptx.ShapeType.line, {
  x: 8.3,
  y: 3.5,
  w: 0,
  h: 1.75,
  line: { color: '5A86AF', width: 1.1, beginArrowType: 'triangle', endArrowType: 'none' }
});

targetSlide.addText('Target boundary: Multi-zone deployment with automated operations and role-based governance', {
  x: 0.45,
  y: 7.18,
  w: 8.6,
  h: 0.2,
  fontFace: 'Segoe UI',
  fontSize: 7,
  color: '6A8093',
  margin: 0
});

pptx.writeFile({ fileName: outFile }).then(() => {
  console.log('Created', outFile);
});
