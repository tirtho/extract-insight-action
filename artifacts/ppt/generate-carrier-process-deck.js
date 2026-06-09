const path = require('path');
const pptxgen = require('pptxgenjs');

const root = path.resolve(__dirname, '..', '..');
const outFile = path.join(root, 'Extract-Insight-Action-Carrier-Process-Playbook.pptx');

const pptx = new pptxgen();
pptx.layout = 'LAYOUT_WIDE';
pptx.author = 'GitHub Copilot';
pptx.company = 'Microsoft';
pptx.subject = 'Carrier process flows with challenge points and accelerator interventions';
pptx.title = 'Extract-Insight-Action - Carrier Process Playbook';
pptx.theme = {
  headFontFace: 'Aptos Display',
  bodyFontFace: 'Aptos',
  lang: 'en-US'
};

const colors = {
  bgLight: 'F6F8FB',
  bgDark: '12344D',
  headerBand: '0F5D75',
  textDark: '12344D',
  textLight: 'FFFFFF',
  muted: '5D7285',
  card: 'FFFFFF',
  border: 'C8D3DD',
  challenge: 'F6D9D9',
  intervention: 'D9F2E6',
  accent: '0B8F6A'
};

const citations = [
  '[1] Triple-I industry overview: iii.org/fact-statistic/facts-statistics-industry-overview',
  '[2] Triple-I auto stats: iii.org/fact-statistic/facts-statistics-auto-insurance',
  '[3] BLS CPI release: bls.gov/news.release/cpi.nr0.htm',
  '[4] NOAA NCEI disasters: ncei.noaa.gov/access/billions/'
].join('  |  ');

const carriers = [
  {
    type: 'Personal Lines Carrier',
    product: 'Personal Auto Claims During Catastrophe Surge',
    why: 'High claim volume, customer response pressure, and rising loss costs make intake-to-settlement speed critical [2][3][4].',
    stages: [
      { name: 'FNOL Intake', challenge: 'Thousands of mixed-format submissions create queue bottlenecks.', use: 'Auto-ingest and classify emails, photos, and forms into claim families.' },
      { name: 'Coverage Triage', challenge: 'Incomplete documentation delays early decisions.', use: 'Completeness scoring and missing-document alerts at first touch.' },
      { name: 'Assessment', challenge: 'Adjusters rebuild chronology manually.', use: 'Prebuilt evidence timeline and anomaly highlights.' },
      { name: 'Settlement', challenge: 'Inconsistent communication drives repeat calls.', use: 'Unified interaction timeline and action prompts for next best step.' }
    ],
    outcomes: [
      'Backlog growth contained during surge periods',
      'Faster first meaningful contact with policyholders',
      'Higher consistency in adjuster decisions'
    ]
  },
  {
    type: 'Commercial Lines Carrier',
    product: 'Middle-Market Package Policy Renewal and Premium Audit',
    why: 'Brokered submissions and audit evidence are document-heavy, and margin pressure makes leakage control essential [1][2].',
    stages: [
      { name: 'Submission Intake', challenge: 'ACORD packages arrive with uneven quality.', use: 'Extract payroll, class code, fleet, and loss history into structured risk view.' },
      { name: 'Underwriting Review', challenge: 'Missing controls trigger rework and referrals.', use: 'Risk completeness and control-gap flags before underwriter review.' },
      { name: 'Premium Audit', challenge: 'Declared vs observed exposure mismatches are found late.', use: 'Automated discrepancy detection and exception queue generation.' },
      { name: 'Renewal Decision', challenge: 'Loss trends are hard to aggregate quickly.', use: 'Precomputed trend summary with linked evidence for decision committee.' }
    ],
    outcomes: [
      'Shorter submission-to-quote cycle',
      'Reduced premium leakage risk',
      'Improved renewal decision confidence'
    ]
  },
  {
    type: 'Specialty / E&S Carrier',
    product: 'High-Hazard Liability Risk Selection and Referral Governance',
    why: 'Non-standard risks are narrative-heavy and require rapid but defensible referral decisions [1][4].',
    stages: [
      { name: 'Broker Submission', challenge: 'Inconsistent narrative packets hide key hazards.', use: 'Normalize varied documents into consistent hazard/control profiles.' },
      { name: 'Referral Decision', challenge: 'Evidence gathering slows authority escalation.', use: 'Auto-generated referral pack with rationale and source links.' },
      { name: 'Policy Structuring', challenge: 'Exclusions and conditions can be misapplied under time pressure.', use: 'Policy condition checkpoints and missing-artifact prompts.' },
      { name: 'Portfolio Monitoring', challenge: 'Concentration drift appears late.', use: 'Segment drift indicators from extracted risk signals.' }
    ],
    outcomes: [
      'Faster specialty decision turnarounds',
      'Higher consistency across underwriting pods',
      'Earlier concentration risk detection'
    ]
  },
  {
    type: 'Reinsurer',
    product: 'Treaty Bordereaux and Cat Event Aggregation',
    why: 'Ceded data inconsistency and event-driven volatility challenge reserve confidence and reporting speed [1][4].',
    stages: [
      { name: 'Cedant Intake', challenge: 'Ceded claims arrive in heterogeneous formats.', use: 'Normalize cedant documents into treaty-ready structured fields.' },
      { name: 'Data Validation', challenge: 'Out-of-tolerance bordereaux entries require manual checks.', use: 'Rule-based exception detection with source traceability.' },
      { name: 'Event Aggregation', challenge: 'Cat losses are hard to roll up quickly across cedants.', use: 'Event/peril clustering and timeline-driven exposure rollups.' },
      { name: 'Reserve and Reporting', challenge: 'Governance needs auditable source lineage.', use: 'Source-to-summary evidence packs for actuarial and finance review.' }
    ],
    outcomes: [
      'Faster monthly/quarterly bordereaux cycles',
      'Improved ceded data confidence',
      'Lower reconciliation friction'
    ]
  }
];

function addHeader(slide, title, subtitle, dark = false) {
  slide.background = { color: dark ? colors.bgDark : colors.bgLight };
  slide.addShape(pptx.ShapeType.rect, {
    x: 0,
    y: 0,
    w: 13.33,
    h: 0.9,
    fill: { color: colors.headerBand },
    line: { color: colors.headerBand }
  });
  slide.addText(title, {
    x: 0.45,
    y: 0.18,
    w: 9.0,
    h: 0.35,
    fontSize: 24,
    bold: true,
    color: colors.textLight,
    margin: 0
  });
  slide.addText(subtitle, {
    x: 0.45,
    y: 0.56,
    w: 12.3,
    h: 0.2,
    fontSize: 10,
    color: 'D6E4EA',
    margin: 0
  });
}

function addSectionDivider(carrier) {
  const slide = pptx.addSlide();
  addHeader(slide, carrier.type, `${carrier.product} | Challenge-first process transformation`, true);

  slide.addShape(pptx.ShapeType.roundRect, {
    x: 0.7,
    y: 1.5,
    w: 12.0,
    h: 4.2,
    rectRadius: 0.1,
    fill: { color: '194A69' },
    line: { color: '2B607F', width: 1 }
  });

  slide.addText('Selected Business Scenario', {
    x: 1.1,
    y: 2.0,
    w: 4.8,
    h: 0.3,
    fontSize: 18,
    bold: true,
    color: '9DD4E6',
    margin: 0
  });

  slide.addText(carrier.product, {
    x: 1.1,
    y: 2.4,
    w: 10.8,
    h: 0.8,
    fontSize: 28,
    bold: true,
    color: colors.textLight,
    margin: 0
  });

  slide.addText('Why this scenario has high urgency', {
    x: 1.1,
    y: 3.5,
    w: 5.4,
    h: 0.26,
    fontSize: 13,
    bold: true,
    color: '9DD4E6',
    margin: 0
  });

  slide.addText(carrier.why, {
    x: 1.1,
    y: 3.8,
    w: 10.8,
    h: 1.0,
    fontSize: 15,
    color: colors.textLight,
    margin: 0
  });

  slide.addText(citations, {
    x: 0.45,
    y: 7.18,
    w: 12.4,
    h: 0.2,
    fontSize: 7,
    color: 'B7C7D3',
    margin: 0
  });
}

function addFlowSlide(carrier) {
  const slide = pptx.addSlide();
  addHeader(slide, `${carrier.type} Process Flow`, `${carrier.product} | Where the accelerator resolves stage-specific challenges`);

  const left = 0.45;
  const top = 1.25;
  const laneW = 2.95;
  const laneGap = 0.28;
  const laneH = 4.7;

  for (let i = 0; i < carrier.stages.length; i += 1) {
    const stage = carrier.stages[i];
    const x = left + i * (laneW + laneGap);

    slide.addShape(pptx.ShapeType.roundRect, {
      x,
      y: top,
      w: laneW,
      h: laneH,
      rectRadius: 0.06,
      fill: { color: colors.card },
      line: { color: colors.border, width: 1 }
    });

    slide.addShape(pptx.ShapeType.rect, {
      x,
      y: top,
      w: laneW,
      h: 0.58,
      fill: { color: 'E8F1F6' },
      line: { color: 'E8F1F6' }
    });

    slide.addText(`${i + 1}. ${stage.name}`, {
      x: x + 0.12,
      y: top + 0.14,
      w: laneW - 0.24,
      h: 0.28,
      fontSize: 12,
      bold: true,
      color: colors.textDark,
      margin: 0
    });

    slide.addShape(pptx.ShapeType.roundRect, {
      x: x + 0.14,
      y: top + 0.76,
      w: laneW - 0.28,
      h: 1.58,
      rectRadius: 0.04,
      fill: { color: colors.challenge },
      line: { color: 'E2BBBB', width: 1 }
    });

    slide.addText('Business challenge', {
      x: x + 0.24,
      y: top + 0.9,
      w: laneW - 0.48,
      h: 0.2,
      fontSize: 10,
      bold: true,
      color: '7B3E3E',
      margin: 0
    });

    slide.addText(stage.challenge, {
      x: x + 0.24,
      y: top + 1.12,
      w: laneW - 0.48,
      h: 1.1,
      fontSize: 10,
      color: '5E3A3A',
      valign: 'top',
      margin: 0
    });

    slide.addShape(pptx.ShapeType.roundRect, {
      x: x + 0.14,
      y: top + 2.56,
      w: laneW - 0.28,
      h: 2.05,
      rectRadius: 0.04,
      fill: { color: colors.intervention },
      line: { color: 'BCE2CF', width: 1 }
    });

    slide.addText('Accelerator intervention', {
      x: x + 0.24,
      y: top + 2.7,
      w: laneW - 0.48,
      h: 0.2,
      fontSize: 10,
      bold: true,
      color: '1E6A53',
      margin: 0
    });

    slide.addText(stage.use, {
      x: x + 0.24,
      y: top + 2.92,
      w: laneW - 0.48,
      h: 1.55,
      fontSize: 10,
      color: '1D5A47',
      valign: 'top',
      margin: 0
    });

    if (i < carrier.stages.length - 1) {
      slide.addShape(pptx.ShapeType.chevron, {
        x: x + laneW + 0.06,
        y: top + 2.2,
        w: 0.16,
        h: 0.26,
        fill: { color: colors.accent },
        line: { color: colors.accent, width: 0.5 }
      });
    }
  }

  slide.addShape(pptx.ShapeType.roundRect, {
    x: 0.45,
    y: 6.15,
    w: 12.43,
    h: 0.78,
    rectRadius: 0.04,
    fill: { color: 'EAF0F4' },
    line: { color: 'D0DBE3', width: 1 }
  });

  slide.addText('Expected business outcomes', {
    x: 0.62,
    y: 6.35,
    w: 2.2,
    h: 0.22,
    fontSize: 10,
    bold: true,
    color: colors.textDark,
    margin: 0
  });

  slide.addText(`- ${carrier.outcomes[0]}\n- ${carrier.outcomes[1]}\n- ${carrier.outcomes[2]}`, {
    x: 2.7,
    y: 6.25,
    w: 8.7,
    h: 0.55,
    fontSize: 10,
    color: colors.textDark,
    margin: 0
  });

  slide.addText(citations, {
    x: 0.45,
    y: 7.18,
    w: 12.4,
    h: 0.2,
    fontSize: 7,
    color: colors.muted,
    margin: 0
  });
}

const titleSlide = pptx.addSlide();
addHeader(
  titleSlide,
  'Extract-Insight-Action | Carrier Process Playbook',
  'Grouped by carrier type: product scenario, stage-level challenges, and intervention points'
);

titleSlide.addShape(pptx.ShapeType.roundRect, {
  x: 0.8,
  y: 1.4,
  w: 11.8,
  h: 4.4,
  rectRadius: 0.1,
  fill: { color: 'FFFFFF' },
  line: { color: colors.border, width: 1 }
});

titleSlide.addText('Deck Structure', {
  x: 1.15,
  y: 1.8,
  w: 2.4,
  h: 0.3,
  fontSize: 18,
  bold: true,
  color: colors.textDark,
  margin: 0
});

titleSlide.addText(
  '1. Personal Lines Carrier\n2. Commercial Lines Carrier\n3. Specialty / E&S Carrier\n4. Reinsurer',
  {
    x: 1.15,
    y: 2.2,
    w: 4.3,
    h: 2.1,
    fontSize: 16,
    color: colors.textDark,
    margin: 0
  }
);

titleSlide.addShape(pptx.ShapeType.roundRect, {
  x: 6.0,
  y: 2.0,
  w: 6.0,
  h: 2.9,
  rectRadius: 0.08,
  fill: { color: 'E9F4FA' },
  line: { color: 'C7DDEB', width: 1 }
});

titleSlide.addText('For each carrier section:', {
  x: 6.3,
  y: 2.3,
  w: 4.3,
  h: 0.24,
  fontSize: 13,
  bold: true,
  color: colors.textDark,
  margin: 0
});

titleSlide.addText(
  '- One high-challenge product/business scenario\n- Process flow with 4 business stages\n- Stage-specific challenge callout\n- Exact accelerator intervention at each stage\n- Outcome summary + source citations',
  {
    x: 6.3,
    y: 2.6,
    w: 5.4,
    h: 2.0,
    fontSize: 12,
    color: colors.textDark,
    margin: 0,
    valign: 'top'
  }
);

titleSlide.addText(citations, {
  x: 0.45,
  y: 7.18,
  w: 12.4,
  h: 0.2,
  fontSize: 7,
  color: colors.muted,
  margin: 0
});

for (const carrier of carriers) {
  addSectionDivider(carrier);
  addFlowSlide(carrier);
}

pptx.writeFile({ fileName: outFile }).then(() => {
  console.log('Created', outFile);
});
