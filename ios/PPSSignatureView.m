#import "PPSSignatureView.h"
#import <OpenGLES/ES2/glext.h>
#import "RSSignatureViewManager.h"

#define       STROKE_WIDTH_SMOOTHING 0.5   // Low pass filter alpha

#define           VELOCITY_CLAMP_MIN 20
#define           VELOCITY_CLAMP_MAX 5000

#define QUADRATIC_DISTANCE_TOLERANCE 3.0   // Minimum distance to make a curve

#define             MAXIMUM_VERTECES 100000


static GLKVector3 StrokeColor = { 0, 0, 0 };
static float clearColor[4] = { 1, 1, 1, 0 };

// Vertex structure containing 3D point and color
struct PPSSignaturePoint
{
	GLKVector3		vertex;
	GLKVector3		color;
};
typedef struct PPSSignaturePoint PPSSignaturePoint;


// Maximum verteces in signature
static const int maxLength = MAXIMUM_VERTECES;


// Append vertex to array buffer
static inline void addVertex(uint *length, PPSSignaturePoint v) {
	if ((*length) >= maxLength) {
		return;
	}

	GLvoid *data = glMapBufferOES(GL_ARRAY_BUFFER, GL_WRITE_ONLY_OES);
	memcpy(data + sizeof(PPSSignaturePoint) * (*length), &v, sizeof(PPSSignaturePoint));
	glUnmapBufferOES(GL_ARRAY_BUFFER);

	(*length)++;
}

static inline CGPoint QuadraticPointInCurve(CGPoint start, CGPoint end, CGPoint controlPoint, float percent) {
	double a = pow((1.0 - percent), 2.0);
	double b = 2.0 * percent * (1.0 - percent);
	double c = pow(percent, 2.0);

	return (CGPoint) {
		a * start.x + b * controlPoint.x + c * end.x,
		a * start.y + b * controlPoint.y + c * end.y
	};
}

static float generateRandom(float from, float to) { return random() % 10000 / 10000.0 * (to - from) + from; }
static float clamp(float min, float max, float value) { return fmaxf(min, fminf(max, value)); }


// Find perpendicular vector from two other vectors to compute triangle strip around line
static GLKVector3 perpendicular(PPSSignaturePoint p1, PPSSignaturePoint p2) {
	GLKVector3 ret;
	ret.x = p2.vertex.y - p1.vertex.y;
	ret.y = -1 * (p2.vertex.x - p1.vertex.x);
	ret.z = 0;
	return ret;
}

static PPSSignaturePoint ViewPointToGL(CGPoint viewPoint, CGRect bounds, GLKVector3 color) {

	return (PPSSignaturePoint) {
		{
			(viewPoint.x / bounds.size.width * 2.0 - 1),
			((viewPoint.y / bounds.size.height) * 2.0 - 1) * -1,
			0
		},
		color
	};
}


@interface PPSSignatureView () {
	// OpenGL state
	EAGLContext *context;
	GLKBaseEffect *effect;

	GLuint vertexArray;
	GLuint vertexBuffer;
	GLuint dotsArray;
	GLuint dotsBuffer;


	// Array of verteces, with current length
	PPSSignaturePoint SignatureVertexData[maxLength];
	uint length;

	PPSSignaturePoint SignatureDotsData[maxLength];
	uint dotsLength;


	// Width of line at current and previous vertex
	float penThickness;
	float previousThickness;


	// Previous points for quadratic bezier computations
	CGPoint previousPoint;
	CGPoint previousMidPoint;
	PPSSignaturePoint previousVertex;
	PPSSignaturePoint currentVelocity;
	UIColor* backgroundColor;
	UIColor* strokeColor;
	NSNumber* minStrokeWidth;
	NSNumber* maxStrokeWidth;
}

@end


@implementation PPSSignatureView {
}

- (void)commonInit {
	context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];

	if (context) {

		time(NULL);

		self.backgroundColor = [UIColor whiteColor];
		self.strokeColor = [UIColor blackColor];
		self.opaque = NO;
		self.minStrokeWidth = [NSNumber numberWithFloat:0.004];
		self.maxStrokeWidth = [NSNumber numberWithFloat:0.03];

		self.context = context;
		self.drawableDepthFormat = GLKViewDrawableDepthFormat24;
		self.enableSetNeedsDisplay = YES;

		// Turn on antialiasing
		self.drawableMultisample = GLKViewDrawableMultisample4X;

		[self setupGL];

		// Capture touches
		UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
		pan.maximumNumberOfTouches = pan.minimumNumberOfTouches = 1;
		pan.cancelsTouchesInView = YES;
		[self addGestureRecognizer:pan];

		// For dotting your i's
		UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)];
		tap.cancelsTouchesInView = YES;
		[self addGestureRecognizer:tap];
	}
	else
		[NSException raise:@"NSOpenGLES2ContextException" format:@"Failed to create OpenGL ES2 context"];
}


- (id)initWithCoder:(NSCoder *)aDecoder
{
	if (self = [super initWithCoder:aDecoder]) [self commonInit];
	return self;
}


- (id)initWithFrame:(CGRect)frame context:(EAGLContext *)ctx
{
	if (self = [super initWithFrame:frame context:ctx]) [self commonInit];
	return self;
}


- (void)dealloc
{
	self.context = nil;
	[self tearDownGL];

	if ([EAGLContext currentContext] == context) {
		[EAGLContext setCurrentContext:nil];
	}

	context = nil;
}


- (void)drawRect:(CGRect)rect
{
	glClearColor(clearColor[0], clearColor[1], clearColor[2], clearColor[3]);
	glClear(GL_COLOR_BUFFER_BIT);

	[effect prepareToDraw];

	// Drawing of signature lines
	if (length > 2) {
		glBindVertexArrayOES(vertexArray);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, length);
	}

	if (dotsLength > 0) {
		glBindVertexArrayOES(dotsArray);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, dotsLength);
	}
}

- (void)erase {
	length = 0;
	dotsLength = 0;
	self.hasSignature = NO;

	[self setNeedsDisplay];
}

- (UIImage*)imageByCombiningImage:(UIImage*)firstImage withImage:(UIImage*)secondImage {
	UIImage *image = nil;

	CGSize newImageSize = CGSizeMake(MAX(firstImage.size.width, secondImage.size.width), MAX(firstImage.size.height, secondImage.size.height));
	if (UIGraphicsBeginImageContextWithOptions != NULL) {
		UIGraphicsBeginImageContextWithOptions(newImageSize, NO, [[UIScreen mainScreen] scale]);
	} else {
		UIGraphicsBeginImageContext(newImageSize);
	}
	[firstImage drawAtPoint:CGPointMake(roundf((newImageSize.width-firstImage.size.width)/2),
																			roundf((newImageSize.height-firstImage.size.height)/2))];
	[secondImage drawAtPoint:CGPointMake(roundf((newImageSize.width-secondImage.size.width)/2),
																			 roundf((newImageSize.height-secondImage.size.height)/2))];
	image = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();

	return image;
}

-(UIImage *) snapshot
{
	UIImage *result = [super snapshot];
	return result;
}

- (UIImage*)rotateImage:(UIImage*)sourceImage clockwise:(BOOL)clockwise
{
	CGSize size = sourceImage.size;
	UIGraphicsBeginImageContext(CGSizeMake(size.height, size.width));
	[[UIImage imageWithCGImage:[sourceImage CGImage]
											 scale:1.0
								 orientation:clockwise ? UIImageOrientationRight : UIImageOrientationLeft]
	 drawInRect:CGRectMake(0,0,size.height ,size.width)];

	UIImage* newImage = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();

	return newImage;
}

- (UIImage*) reduceImage:(UIImage*)image toSize:(CGSize)newSize {
	CGSize scaledSize = newSize;
	float scaleFactor = 1.0;

	if(image.size.width > image.size.height) {
		scaleFactor = image.size.width / image.size.height;
		scaledSize.width = newSize.width;
		scaledSize.height = newSize.height / scaleFactor;
	}
	else {
		scaleFactor = image.size.height / image.size.width;
		scaledSize.height = newSize.height;
		scaledSize.width = newSize.width / scaleFactor;
	}

	NSLog(@"%f x %f", scaledSize.width, scaledSize.height);

	UIGraphicsBeginImageContext(scaledSize);
	CGRect scaledImageRect = CGRectMake( 0.0, 0.0, scaledSize.width, scaledSize.height );
	[image drawInRect:scaledImageRect];

	UIImage* scaledImage = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();

	return scaledImage;
}

- (UIImage *)signatureImage
{
	return [self signatureImage:false withSquare:false];
}
- (UIImage *)signatureImage: (BOOL) rotatedImage
{
	return [self signatureImage:rotatedImage withSquare:false];
}
- (UIImage *)signatureImage: (BOOL) rotatedImage withSquare:(BOOL) square
{
	if (!self.hasSignature)
		return nil;

    // [self addFinalText];
	UIImage *signatureImg;
	UIImage *snapshot = [self snapshot];
	[self erase];

	if ( UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ) {
		//signature
		if (square) {
			signatureImg = [self reduceImage:snapshot toSize: CGSizeMake(400.0f, 400.0f)];
		}
		else {
			signatureImg = snapshot;
		}
	}
	else {
		//rotate iphone signature - iphone's signature screen is always landscape

		if (rotatedImage) {
			if (square) {
				UIImage *rotatedImg = [self rotateImage:snapshot clockwise:false];
				signatureImg = [self reduceImage:rotatedImg toSize: CGSizeMake(400.0f, 400.0f)];
			}
			else {
				UIImage *rotatedImg = [self rotateImage:snapshot clockwise:false];
				signatureImg = rotatedImg;
			}
		}
		else {
			if (square) {
				signatureImg = [self reduceImage:snapshot toSize: CGSizeMake(400.0f, 400.0f)];
			}
			else {
				signatureImg = snapshot;
			}
		}
	}
  if (self.enableDate) {
    return [self imageByCombiningImage:signatureImg withImage:[self getDateImage:signatureImg.size]];
  } else {
    return signatureImg;
  }
}


#pragma mark - Gesture Recognizers


- (void)tap:(UITapGestureRecognizer *)t {
	CGPoint l = [t locationInView:self];

	if (t.state == UIGestureRecognizerStateRecognized) {
		glBindBuffer(GL_ARRAY_BUFFER, dotsBuffer);

		PPSSignaturePoint touchPoint = ViewPointToGL(l, self.bounds, (GLKVector3){1, 1, 1});
		addVertex(&dotsLength, touchPoint);

		PPSSignaturePoint centerPoint = touchPoint;
		centerPoint.color = StrokeColor;
		addVertex(&dotsLength, centerPoint);

		static int segments = 20;
		GLKVector2 radius = (GLKVector2){
			clamp(0.00001, 0.02, penThickness * generateRandom(0.5, 1.5)),
			clamp(0.00001, 0.02, penThickness * generateRandom(0.5, 1.5))
		};
		GLKVector2 velocityRadius = radius;
		float angle = 0;

		for (int i = 0; i <= segments; i++) {

			PPSSignaturePoint p = centerPoint;
			p.vertex.x += velocityRadius.x * cosf(angle);
			p.vertex.y += velocityRadius.y * sinf(angle);

			addVertex(&dotsLength, p);
			addVertex(&dotsLength, centerPoint);

			angle += M_PI * 2.0 / segments;
		}

		addVertex(&dotsLength, touchPoint);

		glBindBuffer(GL_ARRAY_BUFFER, 0);
	}

	[self setNeedsDisplay];
}

- (void)pan:(UIPanGestureRecognizer *)p {

	glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);

	CGPoint v = [p velocityInView:self];
	CGPoint l = [p locationInView:self];

	currentVelocity = ViewPointToGL(v, self.bounds, (GLKVector3){0,0,0});
	float distance = 0.;
	if (previousPoint.x > 0) {
		distance = sqrtf((l.x - previousPoint.x) * (l.x - previousPoint.x) + (l.y - previousPoint.y) * (l.y - previousPoint.y));
	}

	float velocityMagnitude = sqrtf(v.x*v.x + v.y*v.y);
	float clampedVelocityMagnitude = clamp(VELOCITY_CLAMP_MIN, VELOCITY_CLAMP_MAX, velocityMagnitude);
	float normalizedVelocity = (clampedVelocityMagnitude - VELOCITY_CLAMP_MIN) / (VELOCITY_CLAMP_MAX - VELOCITY_CLAMP_MIN);

	float lowPassFilterAlpha = STROKE_WIDTH_SMOOTHING;
	float newThickness = ([self.maxStrokeWidth floatValue] - [self.minStrokeWidth floatValue]) * (1 - normalizedVelocity) + [self.minStrokeWidth floatValue];
	penThickness = penThickness * lowPassFilterAlpha + newThickness * (1 - lowPassFilterAlpha);

	if ([p state] == UIGestureRecognizerStateBegan) {

		previousPoint = l;
		previousMidPoint = l;

		PPSSignaturePoint startPoint = ViewPointToGL(l, self.bounds, (GLKVector3){1, 1, 1});
		previousVertex = startPoint;
		previousThickness = penThickness;

		addVertex(&length, startPoint);
		addVertex(&length, previousVertex);

		self.hasSignature = YES;
	} else if ([p state] == UIGestureRecognizerStateChanged) {

		CGPoint mid = CGPointMake((l.x + previousPoint.x) / 2.0, (l.y + previousPoint.y) / 2.0);

		if (distance > QUADRATIC_DISTANCE_TOLERANCE) {
			// Plot quadratic bezier instead of line
			unsigned int i;

			int segments = (int) distance / 1.5;

			float startPenThickness = previousThickness;
			float endPenThickness = penThickness;
			previousThickness = penThickness;

			for (i = 0; i < segments; i++)
			{
				penThickness = startPenThickness + ((endPenThickness - startPenThickness) / segments) * i;

				CGPoint quadPoint = QuadraticPointInCurve(previousMidPoint, mid, previousPoint, (float)i / (float)(segments));

				PPSSignaturePoint v = ViewPointToGL(quadPoint, self.bounds, StrokeColor);
				[self addTriangleStripPointsForPrevious:previousVertex next:v];

				previousVertex = v;
			}
		} else if (distance > 1.0) {

			PPSSignaturePoint v = ViewPointToGL(l, self.bounds, StrokeColor);
			[self addTriangleStripPointsForPrevious:previousVertex next:v];

			previousVertex = v;
			previousThickness = penThickness;
		}

		previousPoint = l;
		previousMidPoint = mid;

	} else if (p.state == UIGestureRecognizerStateEnded | p.state == UIGestureRecognizerStateCancelled) {

		PPSSignaturePoint v = ViewPointToGL(l, self.bounds, (GLKVector3){1, 1, 1});
		addVertex(&length, v);

		previousVertex = v;
		addVertex(&length, previousVertex);
		[self.manager publishDraggedEvent];
	}

	[self setNeedsDisplay];
}


- (void)setStrokeColor:(UIColor *)strokeColor {
	_strokeColor = strokeColor;
	[self updateStrokeColor];
}


#pragma mark - Private

- (void)updateStrokeColor {
	CGFloat red, green, blue, alpha, white;
	if (effect && self.strokeColor && [self.strokeColor getRed:&red green:&green blue:&blue alpha:&alpha]) {
		effect.constantColor = GLKVector4Make(red, green, blue, alpha);
	} else if (effect && self.strokeColor && [self.strokeColor getWhite:&white alpha:&alpha]) {
		effect.constantColor = GLKVector4Make(white, white, white, alpha);
	} else effect.constantColor = GLKVector4Make(0,0,0,1);
}


- (void)setBackgroundColor:(UIColor *)backgroundColor {
	[super setBackgroundColor:backgroundColor];

	CGFloat red, green, blue, alpha, white;
	if ([backgroundColor getRed:&red green:&green blue:&blue alpha:&alpha]) {
		clearColor[0] = red;
		clearColor[1] = green;
		clearColor[2] = blue;
	} else if ([backgroundColor getWhite:&white alpha:&alpha]) {
		clearColor[0] = white;
		clearColor[1] = white;
		clearColor[2] = white;
	}
}

- (void)bindShaderAttributes {
	glEnableVertexAttribArray(GLKVertexAttribPosition);
	glVertexAttribPointer(GLKVertexAttribPosition, 3, GL_FLOAT, GL_FALSE, sizeof(PPSSignaturePoint), 0);
	//    glEnableVertexAttribArray(GLKVertexAttribColor);
	//    glVertexAttribPointer(GLKVertexAttribColor, 3, GL_FLOAT, GL_FALSE,  6 * sizeof(GLfloat), (char *)12);
}

- (void)setupGL
{
	[EAGLContext setCurrentContext:context];

	effect = [[GLKBaseEffect alloc] init];

	[self updateStrokeColor];


	glDisable(GL_DEPTH_TEST);

	// Signature Lines
	glGenVertexArraysOES(1, &vertexArray);
	glBindVertexArrayOES(vertexArray);

	glGenBuffers(1, &vertexBuffer);
	glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
	glBufferData(GL_ARRAY_BUFFER, sizeof(SignatureVertexData), SignatureVertexData, GL_DYNAMIC_DRAW);
	[self bindShaderAttributes];


	// Signature Dots
	glGenVertexArraysOES(1, &dotsArray);
	glBindVertexArrayOES(dotsArray);

	glGenBuffers(1, &dotsBuffer);
	glBindBuffer(GL_ARRAY_BUFFER, dotsBuffer);
	glBufferData(GL_ARRAY_BUFFER, sizeof(SignatureDotsData), SignatureDotsData, GL_DYNAMIC_DRAW);
	[self bindShaderAttributes];

	// [self drawText:@"Hello World" AtX:10 Y:20];
    // [self addFinalText];

	glBindVertexArrayOES(0);


	// Perspective
	GLKMatrix4 ortho = GLKMatrix4MakeOrtho(-1, 1, -1, 1, 0.1f, 2.0f);
	effect.transform.projectionMatrix = ortho;

	GLKMatrix4 modelViewMatrix = GLKMatrix4MakeTranslation(0.0f, 0.0f, -1.0f);
	effect.transform.modelviewMatrix = modelViewMatrix;

	length = 0;
	penThickness = 0.003;
	previousPoint = CGPointMake(-100, -100);
}

- (void)addTriangleStripPointsForPrevious:(PPSSignaturePoint)previous next:(PPSSignaturePoint)next {
	float toTravel = penThickness / 2.0;

	for (int i = 0; i < 2; i++) {
		GLKVector3 p = perpendicular(previous, next);
		GLKVector3 p1 = next.vertex;
		GLKVector3 ref = GLKVector3Add(p1, p);

		float distance = GLKVector3Distance(p1, ref);
		float difX = p1.x - ref.x;
		float difY = p1.y - ref.y;
		float ratio = -1.0 * (toTravel / distance);

		difX = difX * ratio;
		difY = difY * ratio;

		PPSSignaturePoint stripPoint = {
			{ p1.x + difX, p1.y + difY, 0.0 },
			StrokeColor
		};
		addVertex(&length, stripPoint);

		toTravel *= -1;
	}
}

- (UIImage*)getDateImage:(CGSize)size
{
    CGFloat fontSize = 26;
    CGFloat theta = -0.44f; // 25.2 deg

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateFormat = @"dd/MM/yyyy HH:mm";
    NSDate *date = [NSDate date];

    UILabel *myLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height)];
    myLabel.text = [dateFormatter stringFromDate:date];
    myLabel.font = [UIFont fontWithName:@"Helvetica" size:fontSize];
    myLabel.textColor = [UIColor colorWithRed:1 green:0 blue:0 alpha:0.5];
    myLabel.backgroundColor = [UIColor clearColor];
    myLabel.textAlignment = NSTextAlignmentCenter;

    UIGraphicsBeginImageContext(myLabel.bounds.size);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGPoint center = CGPointMake(size.width / 2.0f, size.height / 2.0f);
    CGContextTranslateCTM(c,center.x,center.y);
    CGContextRotateCTM(c,theta);
    CGContextTranslateCTM(c,-center.x,-center.y);

    [myLabel.layer renderInContext:c];
    UIImage *layerImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return layerImage;
}


- (void)tearDownGL
{
	[EAGLContext setCurrentContext:context];

	glDeleteVertexArraysOES(1, &vertexArray);
	glDeleteBuffers(1, &vertexBuffer);

	glDeleteVertexArraysOES(1, &dotsArray);
	glDeleteBuffers(1, &dotsBuffer);

	effect = nil;
}

@end
