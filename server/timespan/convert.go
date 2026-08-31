package timespan

import (
	"fmt"
	"time"

	"github.com/jinzhu/gorm"
	"momenttally.com/server/generated/gqlmodel"
	"momenttally.com/server/model"
)

// preloadTags preloads span tags in position order. Every read path must use
// this — a plain Preload("Tags") returns rows in incidental storage order,
// which is not label order after a reorder or row rewrite (#159).
func preloadTags(db *gorm.DB) *gorm.DB {
	return db.Preload("Tags", func(db *gorm.DB) *gorm.DB {
		return db.Order("position")
	})
}

// syncNow is the clock for sync timestamps (UpdatedAtUTC, tombstones):
// whole seconds so values round-trip through RFC3339 exactly, which the
// timeSpanChanges checkpoint relies on. Overridable in tests.
var syncNow = func() time.Time { return time.Now().UTC().Truncate(time.Second) }

func timespanToInternal(userID int, start model.Time, end *model.Time, tags []*gqlmodel.InputLabel, note string) (model.TimeSpan, error) {
	_, offset := start.Time().Zone()
	span := model.TimeSpan{
		StartUserTime: start.OmitTimeZone(),
		StartUTC:      start.UTC(),
		UserID:        userID,
		Tags:          tagsToInternal(tags),
		OffsetUTC:     offset,
		Note:          note,
		UpdatedAtUTC:  syncNow(),
	}

	if end != nil {
		if start.Time().After(end.Time()) {
			return span, fmt.Errorf("start must be before end")
		}
		endUser := end.OmitTimeZone()
		span.EndUserTime = &endUser
		endUTC := end.UTC()
		span.EndUTC = &endUTC
	}

	return span, nil
}

func timeSpanToExternal(span model.TimeSpan) *gqlmodel.TimeSpan {
	location := time.FixedZone("unknown", span.OffsetUTC)

	result := gqlmodel.TimeSpan{
		Start:     model.Time(span.StartUTC.In(location)),
		End:       nil,
		ID:        span.ID,
		Labels:    tagsToExternal(span.Tags),
		Note:      span.Note,
		UpdatedAt: model.Time(span.UpdatedAtUTC),
	}
	if span.EndUTC != nil && !span.EndUTC.IsZero() {
		end := *span.EndUTC
		endModel := model.Time(end.In(location))
		result.End = &endModel
	}

	return &result
}

func tagsToExternal(tags []model.TimeSpanTag) []*gqlmodel.Label {
	result := []*gqlmodel.Label{}
	for _, tag := range tags {
		result = append(result, &gqlmodel.Label{
			Key:   tag.Key,
			Value: tag.StringValue,
		})
	}
	return result
}

func tagsToInternal(gqls []*gqlmodel.InputLabel) []model.TimeSpanTag {
	result := make([]model.TimeSpanTag, 0)
	for i, tag := range gqls {
		internal := tagToInternal(*tag)
		internal.Position = i
		result = append(result, internal)
	}
	return result
}

func tagToInternal(gqls gqlmodel.InputLabel) model.TimeSpanTag {
	return model.TimeSpanTag{
		Key:         gqls.Key,
		StringValue: gqls.Value,
	}
}

func tagsToInputTag(tags []model.TimeSpanTag) []*gqlmodel.InputLabel {
	result := make([]*gqlmodel.InputLabel, 0)
	for _, tag := range tags {
		result = append(result, &gqlmodel.InputLabel{
			Key:   tag.Key,
			Value: tag.StringValue,
		})
	}
	return result
}
