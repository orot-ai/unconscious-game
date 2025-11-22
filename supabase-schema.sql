-- ============================================================
-- 무의식게임 가치토큰 시스템 Supabase 스키마
-- 프로젝트: qwlrpimsaxypmkbtenbq
-- ============================================================

-- 1. 사용자 데이터 테이블
CREATE TABLE IF NOT EXISTS user_data (
    user_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    product TEXT,
    pending INTEGER DEFAULT 0 CHECK (pending >= 0),
    received INTEGER DEFAULT 0 CHECK (received >= 0),
    given INTEGER DEFAULT 0 CHECK (given >= 0),
    weekly_given INTEGER DEFAULT 0 CHECK (weekly_given >= 0),
    daily_received INTEGER DEFAULT 0 CHECK (daily_received >= 0),
    weekly_received INTEGER DEFAULT 0 CHECK (weekly_received >= 0),
    last_reset_date DATE,
    last_week_reset DATE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. 대기 중인 토큰 전송 테이블
CREATE TABLE IF NOT EXISTS pending_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    to_user_id TEXT NOT NULL REFERENCES user_data(user_id) ON DELETE CASCADE,
    from_user_id TEXT NOT NULL,
    from_name TEXT NOT NULL,
    amount INTEGER NOT NULL CHECK (amount > 0),
    note TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. 활동 로그 테이블
CREATE TABLE IF NOT EXISTS activities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT REFERENCES user_data(user_id) ON DELETE SET NULL,
    message TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 인덱스
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_pending_tokens_to_user ON pending_tokens(to_user_id);
CREATE INDEX IF NOT EXISTS idx_pending_tokens_created ON pending_tokens(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activities_created ON activities(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activities_user ON activities(user_id);

-- ============================================================
-- 트리거: updated_at 자동 갱신
-- ============================================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_user_data_updated_at
    BEFORE UPDATE ON user_data
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- 함수: 토큰 받기 처리
-- ============================================================

CREATE OR REPLACE FUNCTION accept_pending_token(token_id UUID)
RETURNS JSON AS $$
DECLARE
    v_token RECORD;
    v_result JSON;
BEGIN
    -- 토큰 정보 조회
    SELECT * INTO v_token
    FROM pending_tokens
    WHERE id = token_id;

    IF NOT FOUND THEN
        RETURN json_build_object(
            'success', false,
            'error', 'Token not found'
        );
    END IF;

    -- user_data 업데이트
    UPDATE user_data
    SET
        pending = pending - v_token.amount,
        received = received + v_token.amount,
        daily_received = daily_received + v_token.amount,
        weekly_received = weekly_received + v_token.amount
    WHERE user_id = v_token.to_user_id;

    -- 활동 로그 추가
    INSERT INTO activities (user_id, message)
    VALUES (
        v_token.to_user_id,
        format('%s님이 %sVT를 받았습니다', v_token.from_name, v_token.amount)
    );

    -- 토큰 삭제
    DELETE FROM pending_tokens WHERE id = token_id;

    RETURN json_build_object(
        'success', true,
        'amount', v_token.amount
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 뷰: 사용자 랭킹
-- ============================================================

CREATE OR REPLACE VIEW user_rankings AS
SELECT
    user_id,
    name,
    product,
    received,
    given,
    ROW_NUMBER() OVER (ORDER BY received DESC) as rank
FROM user_data
ORDER BY received DESC;

-- ============================================================
-- Row Level Security (RLS) 활성화
-- ============================================================

ALTER TABLE user_data ENABLE ROW LEVEL SECURITY;
ALTER TABLE pending_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE activities ENABLE ROW LEVEL SECURITY;

-- user_data 정책: 모두 읽기 가능, 본인만 수정 가능
CREATE POLICY "Anyone can view user data"
    ON user_data FOR SELECT
    USING (true);

CREATE POLICY "Users can update own data"
    ON user_data FOR UPDATE
    USING (true)
    WITH CHECK (true);

-- pending_tokens 정책: 모두 읽기 가능, 생성/삭제 가능
CREATE POLICY "Anyone can view pending tokens"
    ON pending_tokens FOR SELECT
    USING (true);

CREATE POLICY "Anyone can create pending tokens"
    ON pending_tokens FOR INSERT
    WITH CHECK (true);

CREATE POLICY "Users can delete own pending tokens"
    ON pending_tokens FOR DELETE
    USING (true);

-- activities 정책: 모두 읽기 가능, 생성 가능
CREATE POLICY "Anyone can view activities"
    ON activities FOR SELECT
    USING (true);

CREATE POLICY "Anyone can create activities"
    ON activities FOR INSERT
    WITH CHECK (true);

-- ============================================================
-- 초기 데이터: 8명의 사용자
-- ============================================================

INSERT INTO user_data (user_id, name, product) VALUES
    ('taewook', '태욱', '비즈니스 실행 코칭'),
    ('dowan', '도완', '유튜브 컨설팅 코칭'),
    ('hayeon', '하연', '라이프사이클 코칭'),
    ('euna', '은아', '자본주의 머니 코칭'),
    ('ray', '래이', '우주머니액팅 코칭'),
    ('saerom', '새롬', 'CRM 개발 코칭'),
    ('jieun', '지은', '닐스 기획 코칭'),
    ('jinseul', '진슬', '스레드 분석기 코칭')
ON CONFLICT (user_id) DO NOTHING;

-- ============================================================
-- 완료
-- ============================================================
